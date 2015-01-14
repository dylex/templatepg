{-# LANGUAGE CPP, DeriveDataTypeable, PatternGuards, DataKinds #-}
-- Copyright 2010, 2011, 2012, 2013 Chris Forno
-- Copyright 2014-2015 Dylan Simon

-- |The Protocol module allows for direct, low-level communication with a
--  PostgreSQL server over TCP/IP. You probably don't want to use this module
--  directly.

module Database.PostgreSQL.Typed.Protocol ( 
    PGDatabase(..)
  , defaultPGDatabase
  , PGConnection
  , PGError(..)
  , pgMessageCode
  , pgTypeEnv
  , pgConnect
  , pgDisconnect
  , pgReconnect
  , pgDescribe
  , pgSimpleQuery
  , pgPreparedQuery
  , pgPreparedLazyQuery
  , pgCloseStatement
  ) where

import Control.Applicative ((<$>), (<$))
import Control.Arrow (second)
import Control.Exception (Exception, throwIO)
import Control.Monad (liftM2, replicateM, when, unless)
#ifdef USE_MD5
import qualified Crypto.Hash as Hash
#endif
import qualified Data.Binary.Get as G
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Char8 as BSC
import Data.ByteString.Internal (w2c)
import qualified Data.ByteString.Lazy as BSL
import Data.ByteString.Lazy.Internal (smallChunkSize)
import qualified Data.ByteString.Lazy.UTF8 as BSLU
import qualified Data.ByteString.UTF8 as BSU
import qualified Data.Foldable as Fold
import Data.IORef (IORef, newIORef, writeIORef, readIORef, atomicModifyIORef, atomicModifyIORef', modifyIORef)
import Data.Int (Int32, Int16)
import qualified Data.Map.Lazy as Map
import Data.Maybe (fromMaybe)
import Data.Monoid (mempty, (<>))
import Data.Typeable (Typeable)
import Data.Word (Word32)
import Network (HostName, PortID(..), connectTo)
import System.IO (Handle, hFlush, hClose, stderr, hPutStrLn)
import System.IO.Unsafe (unsafeInterleaveIO)
import Text.Read (readMaybe)

import Database.PostgreSQL.Typed.Types
import Database.PostgreSQL.Typed.Dynamic

data PGState
  = StateUnknown -- no Sync
  | StatePending -- Sync sent
  -- ReadyForQuery received:
  | StateIdle
  | StateTransaction
  | StateTransactionFailed
  -- Terminate sent or EOF received
  | StateClosed
  deriving (Show, Eq)

-- |Information for how to connect to a database, to be passed to 'pgConnect'.
data PGDatabase = PGDatabase
  { pgDBHost :: HostName -- ^ The hostname (ignored if 'pgDBPort' is 'UnixSocket')
  , pgDBPort :: PortID -- ^ The port, likely either @PortNumber 5432@ or @UnixSocket \"\/tmp\/.s.PGSQL.5432\"@
  , pgDBName :: String -- ^ The name of the database
  , pgDBUser, pgDBPass :: String
  , pgDBDebug :: Bool -- ^ Log all low-level server messages
  , pgDBLogMessage :: MessageFields -> IO () -- ^ How to log server notice messages (e.g., @print . PGError@)
  }

instance Eq PGDatabase where
  PGDatabase h1 s1 n1 u1 p1 _ _ == PGDatabase h2 s2 n2 u2 p2 _ _ =
    h1 == h2 && s1 == s2 && n1 == n2 && u1 == u2 && p1 == p2

-- |An established connection to the PostgreSQL server.
-- These objects are not thread-safe and must only be used for a single request at a time.
data PGConnection = PGConnection
  { connHandle :: Handle
  , connDatabase :: !PGDatabase
  , connPid :: !Word32 -- unused
  , connKey :: !Word32 -- unused
  , connParameters :: Map.Map String String
  , connTypeEnv :: PGTypeEnv
  , connPreparedStatements :: IORef (Integer, Map.Map (String, [OID]) Integer)
  , connState :: IORef PGState
  , connInput :: IORef (G.Decoder PGBackendMessage)
  }

data ColDescription = ColDescription
  { colName :: String
  , colTable :: !OID
  , colNumber :: !Int16
  , colType :: !OID
  , colModifier :: !Int32
  , colBinary :: !Bool
  } deriving (Show)

type MessageFields = Map.Map Char String

-- |PGFrontendMessage represents a PostgreSQL protocol message that we'll send.
-- See <http://www.postgresql.org/docs/current/interactive/protocol-message-formats.html>.
data PGFrontendMessage
  = StartupMessage [(String, String)] -- only sent first
  | CancelRequest !Word32 !Word32 -- sent first on separate connection
  | Bind { statementName :: String, bindParameters :: PGValues, binaryColumns :: [Bool] }
  | Close { statementName :: String }
  -- |Describe a SQL query/statement. The SQL string can contain
  --  parameters ($1, $2, etc.).
  | Describe { statementName :: String }
  | Execute !Word32
  | Flush
  -- |Parse SQL Destination (prepared statement)
  | Parse { statementName :: String, queryString :: String, parseTypes :: [OID] }
  | PasswordMessage BS.ByteString
  -- |SimpleQuery takes a simple SQL string. Parameters ($1, $2,
  --  etc.) aren't allowed.
  | SimpleQuery { queryString :: String }
  | Sync
  | Terminate
  deriving (Show)

-- |PGBackendMessage represents a PostgreSQL protocol message that we'll receive.
-- See <http://www.postgresql.org/docs/current/interactive/protocol-message-formats.html>.
data PGBackendMessage
  = AuthenticationOk
  | AuthenticationCleartextPassword
  | AuthenticationMD5Password BS.ByteString
  -- AuthenticationSCMCredential
  | BackendKeyData Word32 Word32
  | BindComplete
  | CloseComplete
  -- |CommandComplete is bare for now, although it could be made
  --  to contain the number of rows affected by statements in a
  --  later version.
  | CommandComplete BS.ByteString
  -- |Each DataRow (result of a query) is a list of ByteStrings
  --  (or just Nothing for null values, to distinguish them from
  --  emtpy strings). The ByteStrings can then be converted to
  --  the appropriate type by 'pgStringToType'.
  | DataRow PGValues
  | EmptyQueryResponse
  -- |An ErrorResponse contains the severity, "SQLSTATE", and
  --  message of an error. See
  --  <http://www.postgresql.org/docs/current/interactive/protocol-error-fields.html>.
  | ErrorResponse { messageFields :: MessageFields }
  | NoData
  | NoticeResponse { messageFields :: MessageFields }
  -- |A ParameterDescription describes the type of a given SQL
  --  query/statement parameter ($1, $2, etc.). Unfortunately,
  --  PostgreSQL does not give us nullability information for the
  --  parameter.
  | ParameterDescription [OID]
  | ParameterStatus String String
  | ParseComplete
  | PortalSuspended
  | ReadyForQuery PGState
  -- |A RowDescription contains the name, type, table OID, and
  --  column number of the resulting columns(s) of a query. The
  --  column number is useful for inferring nullability.
  | RowDescription [ColDescription]
  deriving (Show)

-- |PGException is thrown upon encountering an 'ErrorResponse' with severity of
--  ERROR, FATAL, or PANIC. It holds the message of the error.
data PGError = PGError MessageFields
  deriving (Typeable)

instance Show PGError where
  show (PGError m) = displayMessage m

instance Exception PGError

-- |Produce a human-readable string representing the message
displayMessage :: MessageFields -> String
displayMessage m = "PG" ++ f 'S' ++ " [" ++ f 'C' ++ "]: " ++ f 'M' ++ '\n' : f 'D'
  where f c = Map.findWithDefault "" c m

makeMessage :: String -> String -> MessageFields
makeMessage m d = Map.fromAscList [('D', d), ('M', m)]

-- |Message SQLState code.
--  See <http://www.postgresql.org/docs/current/static/errcodes-appendix.html>.
pgMessageCode :: MessageFields -> String
pgMessageCode = Map.findWithDefault "" 'C'

defaultLogMessage :: MessageFields -> IO ()
defaultLogMessage = hPutStrLn stderr . displayMessage

-- |A database connection with sane defaults:
-- localhost:5432:postgres
defaultPGDatabase :: PGDatabase
defaultPGDatabase = PGDatabase "localhost" (PortNumber 5432) "postgres" "postgres" "" False defaultLogMessage

connDebug :: PGConnection -> Bool
connDebug = pgDBDebug . connDatabase

connLogMessage :: PGConnection -> MessageFields -> IO ()
connLogMessage = pgDBLogMessage . connDatabase

pgTypeEnv :: PGConnection -> PGTypeEnv
pgTypeEnv = connTypeEnv

#ifdef USE_MD5
md5 :: BS.ByteString -> BS.ByteString
md5 = Hash.digestToHexByteString . (Hash.hash :: BS.ByteString -> Hash.Digest Hash.MD5)
#endif


nul :: B.Builder
nul = B.word8 0

-- |Convert a string to a NULL-terminated UTF-8 string. The PostgreSQL
--  protocol transmits most strings in this format.
pgString :: String -> B.Builder
pgString s = B.stringUtf8 s <> nul

-- |Given a message, determinal the (optional) type ID and the body
messageBody :: PGFrontendMessage -> (Maybe Char, B.Builder)
messageBody (StartupMessage kv) = (Nothing, B.word32BE 0x30000
  <> Fold.foldMap (\(k, v) -> pgString k <> pgString v) kv <> nul)
messageBody (CancelRequest pid key) = (Nothing, B.word32BE 80877102
  <> B.word32BE pid <> B.word32BE key)
messageBody Bind{ statementName = n, bindParameters = p, binaryColumns = bc } = (Just 'B',
  nul <> pgString n
    <> (if any fmt p
          then B.word16BE (fromIntegral $ length p) <> Fold.foldMap (B.word16BE . fromIntegral . fromEnum . fmt) p
          else B.word16BE 0)
    <> B.word16BE (fromIntegral $ length p) <> Fold.foldMap val p
    <> (if or bc
          then B.word16BE (fromIntegral $ length bc) <> Fold.foldMap (B.word16BE . fromIntegral . fromEnum) bc
          else B.word16BE 0))
  where
  fmt (PGBinaryValue _) = True
  fmt _ = False
  val PGNullValue = B.int32BE (-1)
  val (PGTextValue v) = B.word32BE (fromIntegral $ BS.length v) <> B.byteString v
  val (PGBinaryValue v) = B.word32BE (fromIntegral $ BS.length v) <> B.byteString v
messageBody Close{ statementName = n } = (Just 'C', 
  B.char7 'S' <> pgString n)
messageBody Describe{ statementName = n } = (Just 'D',
  B.char7 'S' <> pgString n)
messageBody (Execute r) = (Just 'E',
  nul <> B.word32BE r)
messageBody Flush = (Just 'H', mempty)
messageBody Parse{ statementName = n, queryString = s, parseTypes = t } = (Just 'P',
  pgString n <> pgString s
    <> B.word16BE (fromIntegral $ length t) <> Fold.foldMap B.word32BE t)
messageBody (PasswordMessage s) = (Just 'p',
  B.byteString s <> nul)
messageBody SimpleQuery{ queryString = s } = (Just 'Q',
  pgString s)
messageBody Sync = (Just 'S', mempty)
messageBody Terminate = (Just 'X', mempty)

-- |Send a message to PostgreSQL (low-level).
pgSend :: PGConnection -> PGFrontendMessage -> IO ()
pgSend c@PGConnection{ connHandle = h, connState = sr } msg = do
  writeIORef sr (case msg of Sync -> StatePending ; _ -> StateUnknown)
  when (connDebug c) $ putStrLn $ "> " ++ show msg
  B.hPutBuilder h $ Fold.foldMap B.char7 t <> B.word32BE (fromIntegral $ 4 + BS.length b)
  BS.hPut h b -- or B.hPutBuilder? But we've already had to convert to BS to get length
  where (t, b) = second (BSL.toStrict . B.toLazyByteString) $ messageBody msg

pgFlush :: PGConnection -> IO ()
pgFlush = hFlush . connHandle


getPGString :: G.Get String
getPGString = BSLU.toString <$> G.getLazyByteStringNul

getByteStringNul :: G.Get BS.ByteString
getByteStringNul = fmap BSL.toStrict G.getLazyByteStringNul

getMessageFields :: G.Get MessageFields
getMessageFields = g . w2c =<< G.getWord8 where
  g '\0' = return Map.empty
  g f = liftM2 (Map.insert f . BSU.toString) getByteStringNul getMessageFields

-- |Parse an incoming message.
getMessageBody :: Char -> G.Get PGBackendMessage
getMessageBody 'R' = auth =<< G.getWord32be where
  auth 0 = return AuthenticationOk
  auth 3 = return AuthenticationCleartextPassword
  auth 5 = AuthenticationMD5Password <$> G.getByteString 4
  auth op = fail $ "pgGetMessage: unsupported authentication type: " ++ show op
getMessageBody 't' = do
  numParams <- G.getWord16be
  ParameterDescription <$> replicateM (fromIntegral numParams) G.getWord32be
getMessageBody 'T' = do
  numFields <- G.getWord16be
  RowDescription <$> replicateM (fromIntegral numFields) getField where
  getField = do
    name <- getPGString
    oid <- G.getWord32be -- table OID
    col <- G.getWord16be -- column number
    typ' <- G.getWord32be -- type
    _ <- G.getWord16be -- type size
    tmod <- G.getWord32be -- type modifier
    fmt <- G.getWord16be -- format code
    return $ ColDescription
      { colName = name
      , colTable = oid
      , colNumber = fromIntegral col
      , colType = typ'
      , colModifier = fromIntegral tmod
      , colBinary = toEnum (fromIntegral fmt)
      }
getMessageBody 'Z' = ReadyForQuery <$> (rs . w2c =<< G.getWord8) where
  rs 'I' = return StateIdle
  rs 'T' = return StateTransaction
  rs 'E' = return StateTransactionFailed
  rs s = fail $ "pgGetMessage: unknown ready state: " ++ show s
getMessageBody '1' = return ParseComplete
getMessageBody '2' = return BindComplete
getMessageBody '3' = return CloseComplete
getMessageBody 'C' = CommandComplete <$> getByteStringNul
getMessageBody 'S' = liftM2 ParameterStatus getPGString getPGString
getMessageBody 'D' = do 
  numFields <- G.getWord16be
  DataRow <$> replicateM (fromIntegral numFields) (getField =<< G.getWord32be) where
  getField 0xFFFFFFFF = return PGNullValue
  getField len = PGTextValue <$> G.getByteString (fromIntegral len)
  -- could be binary, too, but we don't know here, so have to choose one
getMessageBody 'K' = liftM2 BackendKeyData G.getWord32be G.getWord32be
getMessageBody 'E' = ErrorResponse <$> getMessageFields
getMessageBody 'I' = return EmptyQueryResponse
getMessageBody 'n' = return NoData
getMessageBody 's' = return PortalSuspended
getMessageBody 'N' = NoticeResponse <$> getMessageFields
getMessageBody t = fail $ "pgGetMessage: unknown message type: " ++ show t

getMessage :: G.Decoder PGBackendMessage
getMessage = G.runGetIncremental $ do
  typ <- G.getWord8
  s <- G.bytesRead
  len <- G.getWord32be
  msg <- getMessageBody (w2c typ)
  e <- G.bytesRead
  let r = fromIntegral len - fromIntegral (e - s)
  when (r > 0) $ G.skip r
  when (r < 0) $ fail "pgReceive: decoder overran message"
  return msg

pgRecv :: Bool -> PGConnection -> IO (Maybe PGBackendMessage)
pgRecv block c@PGConnection{ connHandle = h, connInput = dr } =
  go =<< readIORef dr where
  next = writeIORef dr
  state s d = writeIORef (connState c) s >> next d
  new = G.pushChunk getMessage
  go (G.Done b _ m) = do
    when (connDebug c) $ putStrLn $ "< " ++ show m
    got (new b) m
  go (G.Fail _ _ r) = next (new BS.empty) >> fail r -- not clear how can recover
  go d@(G.Partial r) = do
    b <- (if block then BS.hGetSome else BS.hGetNonBlocking) h smallChunkSize
    if BS.null b
      then Nothing <$ next d
      else go $ r (Just b)
  got :: G.Decoder PGBackendMessage -> PGBackendMessage -> IO (Maybe PGBackendMessage)
  got d (NoticeResponse m) = connLogMessage c m >> go d
  got d m@(ReadyForQuery s) = Just m <$ state s d
  got d m@(ErrorResponse _) = Just m <$ state StateUnknown d
  got d m                   = Just m <$ next d

-- |Receive the next message from PostgreSQL (low-level). Note that this will
-- block until it gets a message.
pgReceive :: PGConnection -> IO PGBackendMessage
pgReceive c = do
  r <- pgRecv True c
  case r of
    Nothing -> do
      writeIORef (connState c) StateClosed
      fail $ "pgReceive: connection closed"
    Just ErrorResponse{ messageFields = m } -> throwIO (PGError m)
    Just m -> return m

-- |Connect to a PostgreSQL server.
pgConnect :: PGDatabase -> IO PGConnection
pgConnect db = do
  state <- newIORef StateUnknown
  prep <- newIORef (0, Map.empty)
  input <- newIORef getMessage
  h <- connectTo (pgDBHost db) (pgDBPort db)
  let c = PGConnection
        { connHandle = h
        , connDatabase = db
        , connPid = 0
        , connKey = 0
        , connParameters = Map.empty
        , connPreparedStatements = prep
        , connState = state
        , connTypeEnv = unknownPGTypeEnv
        , connInput = input
        }
  pgSend c $ StartupMessage
    [ ("user", pgDBUser db)
    , ("database", pgDBName db)
    , ("client_encoding", "UTF8")
    , ("standard_conforming_strings", "on")
    , ("bytea_output", "hex")
    , ("DateStyle", "ISO, YMD")
    , ("IntervalStyle", "iso_8601")
    ]
  pgFlush c
  conn c
  where
  conn c = pgReceive c >>= msg c
  msg c (ReadyForQuery _) = return c
    { connTypeEnv = PGTypeEnv
      { pgIntegerDatetimes = fmap ("on" ==) $ Map.lookup "integer_datetimes" (connParameters c)
      }
    }
  msg c (BackendKeyData p k) = conn c{ connPid = p, connKey = k }
  msg c (ParameterStatus k v) = conn c{ connParameters = Map.insert k v $ connParameters c }
  msg c AuthenticationOk = conn c
  msg c AuthenticationCleartextPassword = do
    pgSend c $ PasswordMessage $ BSU.fromString $ pgDBPass db
    pgFlush c
    conn c
#ifdef USE_MD5
  msg c (AuthenticationMD5Password salt) = do
    pgSend c $ PasswordMessage $ BSC.pack "md5" `BS.append` md5 (md5 (BSU.fromString (pgDBPass db ++ pgDBUser db)) `BS.append` salt)
    pgFlush c
    conn c
#endif
  msg _ m = fail $ "pgConnect: unexpected response: " ++ show m

-- |Disconnect cleanly from the PostgreSQL server.
pgDisconnect :: PGConnection -- ^ a handle from 'pgConnect'
             -> IO ()
pgDisconnect c@PGConnection{ connHandle = h, connState = s } = do
  pgSend c Terminate
  writeIORef s StateClosed
  hClose h

-- |Possibly re-open a connection to a different database, either reusing the connection if the given database is already connected or closing it and opening a new one.
-- Regardless, the input connection must not be used afterwards.
pgReconnect :: PGConnection -> PGDatabase -> IO PGConnection
pgReconnect c@PGConnection{ connDatabase = cd, connState = cs } d = do
  s <- readIORef cs
  if cd == d && s /= StateClosed
    then return c{ connDatabase = d }
    else do
      when (s /= StateClosed) $ pgDisconnect c
      pgConnect d

pgSync :: PGConnection -> IO ()
pgSync c@PGConnection{ connState = sr } = do
  s <- readIORef sr
  case s of
    StateClosed -> fail "pgSync: operation on closed connection"
    StatePending -> wait True
    StateUnknown -> wait False
    _ -> return ()
  where
  wait s = do
    r <- pgRecv s c
    case r of
      Nothing -> do
        pgSend c Sync
        pgFlush c
        wait True
      (Just (ErrorResponse{ messageFields = m })) -> do
        connLogMessage c m
        wait s
      (Just (ReadyForQuery _)) -> return ()
      (Just m) -> do
        connLogMessage c $ makeMessage ("Unexpected server message: " ++ show m) "Each statement should only contain a single query"
        wait s
    
-- |Describe a SQL statement/query. A statement description consists of 0 or
-- more parameter descriptions (a PostgreSQL type) and zero or more result
-- field descriptions (for queries) (consist of the name of the field, the
-- type of the field, and a nullability indicator).
pgDescribe :: PGConnection -> String -- ^ SQL string
                  -> [OID] -- ^ Optional type specifications
                  -> Bool -- ^ Guess nullability, otherwise assume everything is
                  -> IO ([OID], [(String, OID, Bool)]) -- ^ a list of parameter types, and a list of result field names, types, and nullability indicators.
pgDescribe h sql types nulls = do
  pgSync h
  pgSend h $ Parse{ queryString = sql, statementName = "", parseTypes = types }
  pgSend h $ Describe ""
  pgSend h Flush
  pgSend h Sync
  pgFlush h
  ParseComplete <- pgReceive h
  ParameterDescription ps <- pgReceive h
  m <- pgReceive h
  (,) ps <$> case m of
    NoData -> return []
    RowDescription r -> mapM desc r
    _ -> fail $ "describeStatement: unexpected response: " ++ show m
  where
  desc (ColDescription{ colName = name, colTable = tab, colNumber = col, colType = typ }) = do
    n <- nullable tab col
    return (name, typ, n)
  -- We don't get nullability indication from PostgreSQL, at least not directly.
  -- Without any hints, we have to assume that the result can be null and
  -- leave it up to the developer to figure it out.
  nullable oid col
    | nulls && oid /= 0 = do
      -- In cases where the resulting field is tracable to the column of a
      -- table, we can check there.
      (_, r) <- pgPreparedQuery h "SELECT attnotnull FROM pg_catalog.pg_attribute WHERE attrelid = $1 AND attnum = $2" [26, 21] [pgEncodeRep (oid :: OID), pgEncodeRep (col :: Int16)] []
      case r of
        [[s]] -> return $ not $ pgDecodeRep s
        [] -> return True
        _ -> fail $ "Failed to determine nullability of column #" ++ show col
    | otherwise = return True

rowsAffected :: BS.ByteString -> Int
rowsAffected = ra . BSC.words where
  ra [] = -1
  ra l = fromMaybe (-1) $ readMaybe $ BSC.unpack $ last l

-- Do we need to use the ColDescription here always, or are the request formats okay?
fixBinary :: [Bool] -> PGValues -> PGValues
fixBinary (False:b) (PGBinaryValue x:r) = PGTextValue x : fixBinary b r
fixBinary (True :b) (PGTextValue x:r) = PGBinaryValue x : fixBinary b r
fixBinary (_:b) (x:r) = x : fixBinary b r
fixBinary _ l = l

-- |A simple query is one which requires sending only a single 'SimpleQuery'
-- message to the PostgreSQL server. The query is sent as a single string; you
-- cannot bind parameters. Note that queries can return 0 results (an empty
-- list).
pgSimpleQuery :: PGConnection -> String -- ^ SQL string
                   -> IO (Int, [PGValues]) -- ^ The number of rows affected and a list of result rows
pgSimpleQuery h sql = do
  pgSync h
  pgSend h $ SimpleQuery sql
  pgFlush h
  go start where 
  go = (pgReceive h >>=)
  start (RowDescription rd) = go (row (map colBinary rd))
  start (CommandComplete c) = got c
  start EmptyQueryResponse = return (0, [])
  start m = fail $ "pgSimpleQuery: unexpected response: " ++ show m
  row bc (DataRow fs) = second (fixBinary bc fs :) <$> go (row bc)
  row _ (CommandComplete c) = got c
  row _ m = fail $ "pgSimpleQuery: unexpected row: " ++ show m
  got c = return (rowsAffected c, [])

pgPreparedBind :: PGConnection -> String -> [OID] -> PGValues -> [Bool] -> IO (IO ())
pgPreparedBind c@PGConnection{ connPreparedStatements = psr } sql types bind bc = do
  pgSync c
  (p, n) <- atomicModifyIORef' psr $ \(i, m) ->
    maybe ((succ i, m), (False, i)) ((,) (i, m) . (,) True) $ Map.lookup key m
  let sn = show n
  unless p $
    pgSend c $ Parse{ queryString = sql, statementName = sn, parseTypes = types }
  pgSend c $ Bind{ statementName = sn, bindParameters = bind, binaryColumns = bc }
  let
    go = pgReceive c >>= start
    start ParseComplete = do
      modifyIORef psr $ \(i, m) ->
        (i, Map.insert key n m)
      go
    start BindComplete = return ()
    start m = fail $ "pgPrepared: unexpected response: " ++ show m
  return go
  where key = (sql, types)

-- |Prepare a statement, bind it, and execute it.
-- If the given statement has already been prepared (and not yet closed) on this connection, it will be re-used.
pgPreparedQuery :: PGConnection -> String -- ^ SQL statement with placeholders
  -> [OID] -- ^ Optional type specifications (only used for first call)
  -> PGValues -- ^ Paremeters to bind to placeholders
  -> [Bool] -- ^ Requested binary format for result columns
  -> IO (Int, [PGValues])
pgPreparedQuery c sql types bind bc = do
  start <- pgPreparedBind c sql types bind bc
  pgSend c $ Execute 0
  pgSend c Flush
  pgSend c Sync
  pgFlush c
  start
  go
  where
  go = pgReceive c >>= row
  row (DataRow fs) = second (fixBinary bc fs :) <$> go
  row (CommandComplete r) = return (rowsAffected r, [])
  row EmptyQueryResponse = return (0, [])
  row m = fail $ "pgPreparedQuery: unexpected row: " ++ show m

-- |Like 'pgPreparedQuery' but requests results lazily in chunks of the given size.
-- Does not use a named portal, so other requests may not intervene.
pgPreparedLazyQuery :: PGConnection -> String -> [OID] -> PGValues -> [Bool] -> Word32 -- ^ Chunk size (1 is common, 0 is all-at-once)
  -> IO [PGValues]
pgPreparedLazyQuery c sql types bind bc count = do
  start <- pgPreparedBind c sql types bind bc
  unsafeInterleaveIO $ do
    execute
    start
    go
  where
  execute = do
    pgSend c $ Execute count
    pgSend c $ Flush
    pgFlush c
  go = pgReceive c >>= row
  row (DataRow fs) = (fixBinary bc fs :) <$> go
  row PortalSuspended = unsafeInterleaveIO (execute >> go)
  row (CommandComplete _) = return []
  row EmptyQueryResponse = return []
  row m = fail $ "pgPreparedLazyQuery: unexpected row: " ++ show m

-- |Close a previously prepared query (if necessary).
pgCloseStatement :: PGConnection -> String -> [OID] -> IO ()
pgCloseStatement c@PGConnection{ connPreparedStatements = psr } sql types = do
  mn <- atomicModifyIORef psr $ \(i, m) ->
    let (n, m') = Map.updateLookupWithKey (\_ _ -> Nothing) (sql, types) m in ((i, m'), n)
  Fold.forM_ mn $ \n -> do
    pgSync c
    pgSend c $ Close{ statementName = show n }
    pgFlush c
    CloseComplete <- pgReceive c
    return ()
