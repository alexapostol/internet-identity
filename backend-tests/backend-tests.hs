{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE QuasiQuotes #-}

module Main where

import Options.Applicative hiding (empty)
import qualified Data.Map as M
import qualified Data.Set as S
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Text.Hex as H
import qualified Data.ByteString.Lazy as BS
import qualified Data.ByteString.Builder as BS
import qualified Data.Vector as V
import qualified Data.ByteString.Base64.Lazy as Base64
import           Data.CaseInsensitive  ( CI )
import qualified Data.CaseInsensitive as CI
import Control.Monad.Trans
import Control.Monad.Trans.State
import Codec.CBOR.Term
import Codec.CBOR.Read
import Data.Proxy
import Data.Bifunctor
import Data.Word
import Control.Monad.Random.Lazy
import Data.Time.Clock.POSIX
import Text.Printf
import Text.Regex.TDFA ((=~), (=~~))

import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.Ingredients
import Test.Tasty.Ingredients.Basic
import Test.Tasty.Ingredients.Rerun
import Test.Tasty.Runners.AntXML
import Test.Tasty.Options
import Test.Tasty.Runners.Html

import GHC.TypeLits (KnownSymbol, symbolVal)
import Data.Row (empty, (.==), (.+), type (.!), (.!), Label, AllUniqueLabels, Var)
import Codec.Candid (Principal(..))
import qualified Codec.Candid as Candid
import qualified Data.Row.Variants as V

import IC.Types hiding (PublicKey, Timestamp)
import qualified IC.Types
import IC.Ref
import IC.Management
import IC.Hash
import IC.Crypto
import IC.Id.Forms hiding (Blob)
import IC.HTTP.GenR
import IC.HTTP.RequestId
import IC.Certificate hiding (Delegation)
import IC.Certificate.CBOR
import IC.Certificate.Validate
import IC.HashTree hiding (Blob, Hash, Label)
import IC.HashTree.CBOR

import Prometheus hiding (Timestamp)

type IIInterface m = [Candid.candidFile|../src/internet_identity/internet_identity.did|]

-- Pulls in all type definitions as Haskell type aliases
[Candid.candidDefsFile|../src/internet_identity/internet_identity.did|]

httpGet :: String -> HttpRequest
httpGet url = #method .== T.pack "GET"
  .+ #url .== T.pack url
  .+ #headers .== V.empty
  .+ #body .== ""

type Hash = Blob

delegationHash :: Delegation -> Hash
delegationHash d = requestId $ rec $
  [ "pubkey" =: GBlob (d .! #pubkey)
  , "expiration" =: GNat (fromIntegral (d .! #expiration))
  ] ++
  [ "targets" =: GList [ GBlob b | Candid.Principal b <- V.toList ts ]
  | Just ts <- pure $ d .! #targets
  ]


type M = StateT IC IO

dummyUserId :: CanisterId
dummyUserId = EntityId $ BS.pack [0xCA, 0xFF, 0xEE]

controllerId :: CanisterId
controllerId = EntityId "I am the controller"

shorten :: Int -> String -> String
shorten n s = a ++ (if null b then "" else "…")
  where (a,b) = splitAt n s


submitAndRun :: CallRequest -> M CallResponse
submitAndRun r = do
    rid <- lift mkRequestId
    submitRequest rid r
    runToCompletion
    r <- gets (snd . (M.! rid) . requests)
    case r of
      CallResponse r -> return r
      _ -> lift $ assertFailure $ "submitRequest: request status is still " <> show r

submitQuery :: QueryRequest -> M CallResponse
submitQuery r = do
    t <- getTimestamp
    QueryResponse r <- handleQuery t r
    return r

getTimestamp :: M IC.Types.Timestamp
getTimestamp = lift $ do
    t <- getPOSIXTime
    return $ IC.Types.Timestamp $ round (t * 1000_000_000)

mkRequestId :: IO RequestID
mkRequestId = BS.toLazyByteString . BS.word64BE <$> randomIO

setCanisterTimeTo :: Blob -> IC.Types.Timestamp -> M ()
setCanisterTimeTo cid new_time =
 modify $
  \ic -> ic { canisters = M.adjust (\cs -> cs { time = new_time }) (EntityId cid) (canisters ic) }

callManagement :: forall s a b.
  HasCallStack =>
  KnownSymbol s =>
  (a -> IO b) ~ (ICManagement IO .! s) =>
  Candid.CandidArg a =>
  Candid.CandidArg b =>
  EntityId -> Label s -> a -> M b
callManagement user_id l x = do
  r <- submitAndRun $
    CallRequest (EntityId mempty) user_id (symbolVal l) (Candid.encode x)
  case r of
    Rejected (_code, msg) -> lift $ assertFailure $ "Management call got rejected:\n" <> msg
    Replied b -> case Candid.decode b of
      Left err -> lift $ assertFailure err
      Right y -> return y

queryII :: forall s a b.
  HasCallStack =>
  KnownSymbol s =>
  (a -> IO b) ~ (IIInterface IO .! s) =>
  Candid.CandidArg a =>
  Candid.CandidArg b =>
  BS.ByteString -> EntityId -> Label s -> a -> M b
queryII cid user_id l x = do
  r <- submitQuery $ QueryRequest (EntityId cid) user_id (symbolVal l) (Candid.encode x)
  case r of
    Rejected (_code, msg) -> lift $ assertFailure $ "II query got rejected:\n" <> msg
    Replied b -> case Candid.decode b of
      Left err -> lift $ assertFailure err
      Right y -> return y

queryIIReject :: forall s a b.
  HasCallStack =>
  KnownSymbol s =>
  (a -> IO b) ~ (IIInterface IO .! s) =>
  Candid.CandidArg a =>
  BS.ByteString -> EntityId -> Label s -> a -> M ()
queryIIReject cid user_id l x = do
  r <- submitQuery $ QueryRequest (EntityId cid) user_id (symbolVal l) (Candid.encode x)
  case r of
    Rejected _ -> return ()
    Replied _ -> lift $ assertFailure "queryIIReject: Unexpected reply"

queryIIRejectWith :: forall s a b.
  HasCallStack =>
  KnownSymbol s =>
  (a -> IO b) ~ (IIInterface IO .! s) =>
  Candid.CandidArg a =>
  BS.ByteString -> EntityId -> Label s -> a -> String -> M ()
queryIIRejectWith cid user_id l x expectedMessagePattern = do
  r <- submitQuery $ QueryRequest (EntityId cid) user_id (symbolVal l) (Candid.encode x)
  case r of
    Rejected (_code, msg) ->
      if not (msg =~ expectedMessagePattern)
      then liftIO $ assertFailure $ printf "expected error matching %s, got: %s" (show expectedMessagePattern) (show msg)
      else return ()
    Replied _ -> lift $ assertFailure "queryIIRejectWith: Unexpected reply"

callII :: forall s a b.
  HasCallStack =>
  KnownSymbol s =>
  (a -> IO b) ~ (IIInterface IO .! s) =>
  Candid.CandidArg a =>
  Candid.CandidArg b =>
  BS.ByteString -> EntityId -> Label s -> a -> M b
callII cid user_id l x = do
  r <- submitAndRun $ CallRequest (EntityId cid) user_id (symbolVal l) (Candid.encode x)
  case r of
    Rejected (_code, msg) -> lift $ assertFailure $ "II call got rejected:\n" <> msg
    Replied b -> case Candid.decode b of
      Left err -> lift $ assertFailure err
      Right y -> return y

callIIReject :: forall s a b.
  HasCallStack =>
  KnownSymbol s =>
  (a -> IO b) ~ (IIInterface IO .! s) =>
  Candid.CandidArg a =>
  BS.ByteString -> EntityId -> Label s -> a -> M ()
callIIReject cid user_id l x = do
  r <- submitAndRun $
    CallRequest (EntityId cid) user_id (symbolVal l) (Candid.encode x)
  case r of
    Rejected _ -> return ()
    Replied _ -> lift $ assertFailure "callIIReject: Unexpected reply"

callIIRejectWith :: forall s a b.
  HasCallStack =>
  KnownSymbol s =>
  (a -> IO b) ~ (IIInterface IO .! s) =>
  Candid.CandidArg a =>
  BS.ByteString -> EntityId -> Label s -> a -> String  -> M ()
callIIRejectWith cid user_id l x expectedMessagePattern = do
  r <- submitAndRun $
    CallRequest (EntityId cid) user_id (symbolVal l) (Candid.encode x)
  case r of
    Rejected (_code, msg) ->
      if not (msg =~ expectedMessagePattern)
      then liftIO $ assertFailure $ printf "expected error matching %s, got: %s" (show expectedMessagePattern) (show msg)
      else return ()
    Replied _ -> lift $ assertFailure "callIIRejectWith: Unexpected reply"


-- Some common devices
-- NOTE: we write the actual key content here, as opposed to generating it
-- (e.g. with 'createSecretKeyWebAuthnECDSA'). This ensures the key contents
-- are stable.
-- See also: https://github.com/dfinity/ic-hs/issues/59
webauth1PK :: PublicKey
webauth1PK = "0^0\f\ACK\n+\ACK\SOH\EOT\SOH\131\184C\SOH\SOH\ETXN\NUL\165\SOH\STX\ETX& \SOH!X lR\190\173]\245, \138\155\FS{\224\166\bGW>[\228\172O\224\142\164\128\&6\208\186\GS*\207\"X \179=\174\184;\201\199}\138\215b\253h\227\234\176\134\132\228c\196\147Q\179\171*\DC4\164\NUL\DC3\131\135"
webauth1ID :: EntityId
webauth1ID = EntityId $ mkSelfAuthenticatingId webauth1PK
device1 :: DeviceData
device1 = empty
    .+ #alias .== "device1"
    .+ #pubkey .== webauth1PK
    .+ #credential_id .== Nothing
    .+ #purpose .== enum #authentication
    .+ #key_type .== enum #cross_platform

webauth2SK :: SecretKey
webauth2SK = createSecretKeyWebAuthnRSA "foobar2"
-- The content here doesn't matter as long as it's different from webauth1PK
webauth2PK = toPublicKey webauth2SK
webauth2PK :: PublicKey
webauth2ID :: EntityId
webauth2ID = EntityId $ mkSelfAuthenticatingId webauth2PK
device2 :: DeviceData
device2 = empty
    .+ #alias .== "device2"
    .+ #pubkey .== webauth2PK
    .+ #credential_id .== Just "foobar"
    .+ #purpose .== enum #authentication
    .+ #key_type .== enum #platform

anonymousID :: EntityId
anonymousID = EntityId "\x04"

-- Check that the user has the following device data
lookupIs
    :: Blob -- ^ canister ID
    -> Word64 -- ^ user (anchor) number
    -> [DeviceData] -> M ()
lookupIs cid user_number ds = do
  r <- queryII cid dummyUserId #lookup user_number
  liftIO $ r @?= V.fromList ds

addTS :: (a, b, c, d) -> e -> (a, b, c, e)
addTS (a,b,c, _) ts = (a,b,c,ts)

assertStats :: HasCallStack => Blob -> Word64 -> M()
assertStats cid expUsers = do
  s <- queryII cid dummyUserId #stats ()
  lift $ s .! #users_registered @?= expUsers

assertVariant :: (HasCallStack, KnownSymbol l, V.Forall r Show) => Label l -> V.Var r -> M ()
assertVariant label var = case V.view label var of
  Just _ -> return ()
  Nothing -> liftIO $ assertFailure $ printf "expected variant %s, got: %s" (show label) (show var)

mustGetUserNumber :: HasCallStack => RegisterResponse -> M Word64
mustGetUserNumber response = case V.view #registered response of
  Just r -> return (r .! #user_number)
  Nothing -> liftIO $ assertFailure $ "expected to get 'registered' response, got " ++ show response

assertRightS :: MonadIO m  => Either String a -> m a
assertRightS (Left e) = liftIO $ assertFailure e
assertRightS (Right x) = pure x

assertRightT :: MonadIO m  => Either T.Text a -> m a
assertRightT (Left e) = liftIO $ assertFailure (T.unpack e)
assertRightT (Right x) = pure x

decodeTree :: BS.ByteString -> Either T.Text HashTree
decodeTree s =
    first (\(DeserialiseFailure _ s) -> "CBOR decoding failure: " <> T.pack s)
        (deserialiseFromBytes decodeTerm s)
    >>= begin
  where
    begin (leftOver, _)
      | not (BS.null leftOver) = Left $ "Left-over bytes: " <> T.pack (shorten 20 (show leftOver))
    begin (_, TTagged 55799 t) = parseHashTree t
    begin _ = Left "Expected CBOR request to begin with tag 55799"

-- | The actual tests.
tests :: FilePath -> TestTree
tests wasm_file = testGroup "Tests" $ upgradeGroups $
  [ withoutUpgrade $ iiTest "installs" $ \ _cid ->
    return ()
  , withoutUpgrade $ iiTest "installs and upgrade" $ \ cid ->
    doUpgrade cid

  , withUpgrade $ \should_upgrade -> iiTest "lookup on fresh" $ \cid -> do
    assertStats cid 0
    when should_upgrade $ doUpgrade cid
    assertStats cid 0
    lookupIs cid 123 []

  , withUpgrade $ \should_upgrade -> testCase "upgrade from stable memory backup" $ withIC $ do
    -- See test-stable-memory-rdmx6-jaaaa-aaaaa-aaadq-cai.md for providence
    t <- getTimestamp
    -- Need a fixed id for this to work
    let cid = fromPrincipal "rdmx6-jaaaa-aaaaa-aaadq-cai"
    createEmptyCanister (EntityId cid) (S.singleton controllerId) t
    -- Load a backup. This backup is taking from the messaging subnet installation
    -- on 2021-04-29
    stable_memory <- lift $ BS.readFile "test-stable-memory-rdmx6-jaaaa-aaaaa-aaadq-cai.bin"
    -- Upload a dummy module that populates the stable memory
    upload_wasm <- lift $ BS.readFile "stable-memory-setter.wasm"
    callManagement controllerId #install_code $ empty
      .+ #mode .== enum #install
      .+ #canister_id .== Candid.Principal cid
      .+ #wasm_module .== upload_wasm
      .+ #arg .== stable_memory
    doUpgrade cid

    when should_upgrade $ doUpgrade cid
    s <- queryII cid dummyUserId #stats ()
    lift $ s .! #users_registered @?= 31
    -- The actual value in the dump is 8B, but it's way too large
    -- and should be auto-corrected on upgrade
    lift $ s .! #assigned_user_number_range @?= (10_000, 10_000 + 3_774_873)
    lookupIs cid 9_999 []
    lookupIs cid 10_000 [#alias .== "Desktop" .+ #credential_id .== Just "c\184\175\179\134\221u}\250[\169U\v\202f\147g\ETBvo9[\175\173\144R\163\132\237\196F\177\DC2(\188\185\203hI\128\187Z\129'\v1\212\185V\ETB\135)m@ M1\233l\ESC8kI\132" .+ #pubkey .== "0^0\f\ACK\n+\ACK\SOH\EOT\SOH\131\184C\SOH\SOH\ETXN\NUL\165\SOH\STX\ETX& \SOH!X \238o!-\ESC\148\252\192\DC4\240P\176\135\240j\211AW\255S\193\153\129\227\151hB\177dK\n\FS\"X \rk\197\238\a{\210\&0\v<\134\223\135\170_\223\144\210V\208\DC3\RS\251\228D$3\r\232\176\EOTq" .+ #purpose .== enum #authentication .+ #key_type .== enum #unknown ]
    lookupIs cid 10_002 [#alias .== "andrew-mbp" .+ #credential_id .== Just "\SOH\191#%\217u\247\178L-K\182\254\249J.m\187\179_I\ACK\137\244`\163o\SI\150qz\197Hz\214\&8\153\239\213\159\208\RS\243\138\171\138\"\139\173\170\ESC\148\205\129\149ri\\Dn,7\151\146\175\DEL" .+ #pubkey .== "0^0\f\ACK\n+\ACK\SOH\EOT\SOH\131\184C\SOH\SOH\ETXN\NUL\165\SOH\STX\ETX& \SOH!X rMm*\229BDe\SOH4\228u\170\206\216\216-ER\v\166r\217\137,\141\227M*@\230\243\"X \225\248\159\191\242\224Z>\241\163\\\GS\155\178\222\139^\136V\253q\v\SUBSJ\bA\131\\\183\147\170" .+ #purpose .== enum #authentication .+ #key_type .== enum #unknown,#alias .== "andrew phone chrome" .+ #credential_id .== Just ",\235x\NUL\a\140`~\148\248\233C/\177\205\158\ETX0\129\167" .+ #pubkey .== "0^0\f\ACK\n+\ACK\SOH\EOT\SOH\131\184C\SOH\SOH\ETXN\NUL\165\SOH\STX\ETX& \SOH!X \140\169\203@\ETX\CAN\ETB,\177\153\179\223/|`\US\STX\252r\190s(.\188\136\171\SI\181V*\174@\"X \245<\174AbV\225\234\ENQ\146\247\129\245\ACK\200\205\217\250g\219\179)\197\252\164i\172kXh\180\205" .+ #purpose .== enum #authentication .+ #key_type .== enum #unknown]
    lookupIs cid 10_029 [#alias .== "Pixel" .+ #credential_id .== Just "\SOH\146\238\160b\223\132\205\231b\239\243F\170\163\167\251D\241\170\EM\216\136\174@r\149\183|LuKu[+{\144\217\ETBL\f\244\GS>\179\146\143\RS\179\DLE\227\179\164\188\NULDQy\223\SI\132\183\248\177\219" .+ #pubkey .== "0^0\f\ACK\n+\ACK\SOH\EOT\SOH\131\184C\SOH\SOH\ETXN\NUL\165\SOH\STX\ETX& \SOH!X \200B>\DEL\GS\248\220\145\245\153\221\&6\131\243uAQCAd>\145k\nw\233\&5\218\SUB~_\244\"X O]7\167=n\ESC\SUB\198\235\208\215s\158\191Gz\143\136\237i\146\203\&6\182\196\129\239\238\SOH\180b" .+ #purpose .== enum #authentication .+ #key_type .== enum #unknown]
    -- This user record has been created manullay with dfx and our test
    -- webauth1PK has been added, so that we can actually log into this now
    let dfxPK =  "0*0\ENQ\ACK\ETX+ep\ETX!\NUL\241\186;\128\206$\243\130\250\&2\253\a#<\235\142\&0]W\218\254j\211\209\192\SO@\DC3\NAKi&1"
    lookupIs cid 10_030 [#alias .== "dfx" .+ #credential_id .== Nothing .+ #pubkey .== dfxPK .+ #purpose .== enum #authentication .+ #key_type .== enum #unknown,#alias .== "testkey" .+ #credential_id .== Nothing .+ #pubkey .== webauth1PK .+ #purpose .== enum #authentication .+ #key_type .== enum #unknown]
    callII cid webauth1ID #remove (10_030, dfxPK)
    lookupIs cid 10_030 [#alias .== "testkey" .+ #credential_id .== Nothing .+ #pubkey .== webauth1PK .+ #purpose .== enum #authentication .+ #key_type .== enum #unknown]
    let delegationArgs = (10_030, "example.com", "dummykey", Nothing)
    (userPK,_) <- callII cid webauth1ID #prepare_delegation delegationArgs
    -- Check that we get the same user key; this proves that the salt was
    -- recovered from the backup
    lift $ userPK @?= "0<0\x0c\&\x06\&\x0a\&+\x06\&\x01\&\x04\&\x01\&\x83\&\xb8\&C\x01\&\x02\&\x03\&,\x00\&\x0a\&\x00\&\x00\&\x00\&\x00\&\x00\&\x00\&\x00\&\x07\&\x01\&\x01\&:\x89\&&\x91\&M\xd1\&\xc8\&6\xec\&g\xba\&f\xac\&d%\xc2\&\x1d\&\xff\&\xd3\&\xca\&\x5c\&Yh\x85\&_\x87\&x\x0a\&\x1e\&\xc5\&y\x85\&"
  ]


  where
    withIC act = do
      ic <- initialIC
      evalStateT act ic

    iiTestWithInit name (l, u) act = testCase name $ withIC $ do
      wasm <- lift $ BS.readFile wasm_file
      r <- callManagement controllerId #create_canister (#settings .== Nothing)
      let Candid.Principal cid = r .! #canister_id
      callManagement controllerId #install_code $ empty
        .+ #mode .== enum #install
        .+ #canister_id .== Candid.Principal cid
        .+ #wasm_module .== wasm
        .+ #arg .== Candid.encode (Just (#assigned_user_number_range .== (l :: Word64, u :: Word64)))
      act cid

    iiTest name act = testCase name $ withIC $ do
      wasm <- lift $ BS.readFile wasm_file
      r <- callManagement controllerId #create_canister (#settings .== Nothing)
      let Candid.Principal cid = r .! #canister_id
      callManagement controllerId #install_code $ empty
        .+ #mode .== V.IsJust #install ()
        .+ #canister_id .== Candid.Principal cid
        .+ #wasm_module .== wasm
        .+ #arg .== Candid.encode (Nothing :: Maybe InternetIdentityInit) -- default value
      act cid

    withUpgrade act = ([act False], [act True])
    withoutUpgrade act = ([act], [])

    upgradeGroups :: [([TestTree], [TestTree])] -> [TestTree]
    upgradeGroups ts =
      [ testGroup "without upgrade" (concat without)
      , testGroup "with upgrade" (concat with)
      ]
      where (without, with) = unzip ts

    doUpgrade cid = do
      wasm <- liftIO $ BS.readFile wasm_file
      callManagement controllerId #install_code $ empty
        .+ #mode .== V.IsJust #upgrade ()
        .+ #canister_id .== Candid.Principal cid
        .+ #wasm_module .== wasm
        .+ #arg .== Candid.encode ()

    getChallenge cid webauthID = do
      challenge <- callII cid webauthID #create_challenge ()
      pure $ #key .== challenge .! #challenge_key .+ #chars .== T.pack "a"

    -- Go through a challenge request/registration flow for this device.
    -- NOTE: this (dummily) solves the challenge with the string "a", which is
    -- returned by the backend when compiled with II_DUMMY_CAPTCHA.
    register cid webauthID device =
      getChallenge cid webauthID >>= callII cid webauthID #register . (device,)

asHex :: Blob -> String
asHex = T.unpack . H.encodeHex . BS.toStrict

fromPrincipal :: T.Text -> Blob
fromPrincipal s = cid
  where Right (Candid.Principal cid) = Candid.parsePrincipal s

enum :: (AllUniqueLabels r, KnownSymbol l, (r .! l) ~ ()) => Label l -> Var r
enum l = V.IsJust l ()

-- Configuration: The Wasm file to test
newtype WasmOption = WasmOption String

instance IsOption WasmOption where
  defaultValue = WasmOption "../internet_identity.wasm"
  parseValue = Just . WasmOption
  optionName = return "wasm"
  optionHelp = return "webassembly module of the identity provider"
  optionCLParser = mkOptionCLParser (metavar "WASM")


wasmOption :: OptionDescription
wasmOption = Option (Proxy :: Proxy WasmOption)

main :: IO ()
main = defaultMainWithIngredients ingredients $ askOption $ \(WasmOption wasm) -> tests wasm
  where
    ingredients =
      [ rerunningTests
        [ listingTests
        , includingOptions [wasmOption]
        , antXMLRunner `composeReporters` htmlRunner `composeReporters` consoleTestReporter
        ]
      ]
