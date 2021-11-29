{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DerivingStrategies    #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NoImplicitPrelude     #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE AllowAmbiguousTypes        #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE DeriveAnyClass             #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NoImplicitPrelude          #-}
{-# LANGUAGE PartialTypeSignatures      #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE TypeOperators              #-}
{-# LANGUAGE ViewPatterns               #-}

module VidBid
    (
    VidBIdStateMachineSchema
    , contract
    ) where

import           Control.Monad                hiding (fmap)
import           Data.Aeson                   (FromJSON, ToJSON)
import           Data.Monoid                  (Last (..))
import           Data.Text                    (Text, pack)
import qualified Data.ByteString.Char8        as C

import           GHC.Generics                 (Generic)
import           Ledger                       hiding (singleton)
import           Ledger.Ada                   as Ada
import           Ledger.Constraints           as Constraints
import           Ledger.Typed.Tx              (TypedScriptTxOut (..))
import qualified Ledger.Typed.Scripts         as Scripts
import qualified Ledger.Value                 as V

import           Plutus.Contract              as Contract
import           Plutus.Contract.StateMachine as SM
import qualified PlutusTx

import           Data.Aeson                   (FromJSON, ToJSON)
import           GHC.Generics                 (Generic)
import           Schema                       (ToSchema)
import qualified Prelude
import           Prelude                      (Semigroup (..), Show (..), String)
import qualified PlutusTx.Prelude
import           PlutusTx.Prelude              hiding (Semigroup(..), check, unless)

import           VidBidMint

newtype HashedString = HashedString BuiltinByteString deriving newtype (PlutusTx.ToData, PlutusTx.FromData, PlutusTx.UnsafeFromData, Show, FromJSON, ToJSON, ToSchema)

PlutusTx.makeLift ''HashedString

newtype ClearString = ClearString BuiltinByteString deriving newtype (PlutusTx.ToData, PlutusTx.FromData, PlutusTx.UnsafeFromData, Show, FromJSON, ToJSON, ToSchema)
PlutusTx.makeLift ''ClearString

newtype VidBidTokenValue = VidBidTokenValue Value deriving newtype (PlutusTx.ToData, PlutusTx.FromData, PlutusTx.UnsafeFromData, Show, FromJSON, ToJSON, ToSchema)
PlutusTx.makeLift ''VidBidTokenValue

newtype VidOwnerPkh = VidOwnerPkh PubKeyHash deriving newtype (PlutusTx.ToData, PlutusTx.FromData, PlutusTx.UnsafeFromData, Show, FromJSON, ToJSON, ToSchema)
PlutusTx.makeLift ''VidOwnerPkh

hashString :: String -> HashedString
hashString = HashedString . sha2_256 . toBuiltin . C.pack

-- create a redeemer script for the guessing VidBId by lifting the
-- string to its on-chain representation
clearString :: String -> ClearString
clearString = ClearString . toBuiltin . C.pack

-- | State of the guessing vidBId
-- | State of the guessing vidBId
data VidBIdState =
    Initialised VidBidTokenValue
    -- ^ Initial state. In this state only the 'MintTokens' action is allowed.
    | Opened VidBidTokenValue VidOwnerPkh
    | Bided VidBidTokenValue VidOwnerPkh
    | Closed VidBidTokenValue
    -- ^ Funds have been locked. In this state only the 'Guess' action is
    --   allowed.
    | Destroyed
    -- ^ All funds were unlocked.
    deriving stock (Prelude.Show, Generic)
    deriving anyclass (ToJSON, FromJSON)
PlutusTx.unstableMakeIsData ''VidBIdState
PlutusTx.makeLift ''VidBIdState


-- | Inputs (actions)
data VidBIdInput =
    MintToken VidOwnerPkh
    | Open VidOwnerPkh
    | Bid
    | PayDay
    | Grab
    | Destroy
    deriving stock (Prelude.Show, Generic)
    deriving anyclass (ToJSON, FromJSON)
PlutusTx.unstableMakeIsData ''VidBIdInput
PlutusTx.makeLift ''VidBIdInput

data VidBidOutput =
    VidBidOutput
        { auctionState :: Last VidBIdState
        , auctionValue :: Last Value
        }
        deriving stock (Generic, Show)
        deriving anyclass (ToJSON, FromJSON)

{-# INLINABLE transition #-}
transition :: State VidBIdState -> VidBIdInput -> Maybe (TxConstraints Void Void, State VidBIdState)
transition State{stateData=oldData, stateValue=oldValue} input = case (oldData, input) of
    (Initialised (VidBidTokenValue tokenVal), MintToken (VidOwnerPkh ownerPkh)) ->
        let constraints = Constraints.mustMintValue tokenVal <>
                          Constraints.mustPayToPubKey ownerPkh tokenVal
        in
        Just ( constraints
             , State
                { stateData = Closed (VidBidTokenValue tokenVal)
                , stateValue = oldValue
                }
             )
    (Closed (VidBidTokenValue tokenVal), Open ownerPkh) ->
        let constraints = mempty
        in
        Just ( constraints
             , State
                { stateData = Opened (VidBidTokenValue tokenVal) ownerPkh
                , stateValue = oldValue + tokenVal
                }
             )

checkGuess :: HashedString -> ClearString -> Bool
checkGuess (HashedString actual) (ClearString guess') = actual == sha2_256 guess'


type VidBIdStateMachine = SM.StateMachine VidBIdState VidBIdInput

{-# INLINABLE machine #-}
machine :: StateMachine VidBIdState VidBIdInput
machine = SM.mkStateMachine Nothing transition isFinal where
    isFinal Destroyed = True
    isFinal _         = False

{-# INLINABLE mkVidBidValidator #-}
mkVidBidValidator :: Scripts.ValidatorType VidBIdStateMachine
mkVidBidValidator = SM.mkValidator machine

typedVidbidValidator :: Scripts.TypedValidator VidBIdStateMachine
typedVidbidValidator = Scripts.mkTypedValidator @VidBIdStateMachine
    $$(PlutusTx.compile [|| mkVidBidValidator ||])
    $$(PlutusTx.compile [|| wrap ||])
    where
        wrap = Scripts.wrapValidator

mintingPolicy :: Scripts.MintingPolicy
mintingPolicy = Scripts.forwardingMintingPolicy typedVidbidValidator

client :: SM.StateMachineClient VidBIdState VidBIdInput
client = SM.mkStateMachineClient $ SM.StateMachineInstance machine typedVidbidValidator

data InitArgs = InitArgs
    { initVidId     :: TokenName
    , initOwnerPkh  :: PubKeyHash
    }
    deriving stock ( Show, Generic)
    deriving anyclass (FromJSON, ToJSON, ToSchema)

init :: ( AsContractError e
            , AsSMContractError e
            ) => Promise () VidBIdStateMachineSchema e ()
init = endpoint @"init" @InitArgs $ \(InitArgs initVidId initOwnerPkh) -> do
    pkh         <- Contract.ownPubKeyHash
    let tokenVal = VidBidTokenValue (VidBidMint.getTokenValue pkh initVidId)
        ownerPkh = VidOwnerPkh initOwnerPkh
        lookups  = Constraints.mintingPolicy (policy pkh)
    void $ SM.runInitialise client (Initialised tokenVal) mempty
    void $ SM.runStepWith lookups mempty client (MintToken ownerPkh)

open :: ( AsContractError e
            , AsSMContractError e
            ) => Promise () VidBIdStateMachineSchema e ()
open = endpoint @"open" $ \() -> do
    pkh         <- Contract.ownPubKeyHash
    let ownerPkh  = VidOwnerPkh pkh
    void $ SM.runStep client (Open ownerPkh)


lookup :: ( AsContractError e
            , AsSMContractError e
            ) => Promise () VidBIdStateMachineSchema e ()
lookup = endpoint @"lookup" $ \() -> do
  logInfo  @String "Fetching contract state "
  maybeState <- SM.getOnChainState client
  case maybeState of
    Just (onChainState, _)  ->
      do
        let OnChainState{ocsTxOut=TypedScriptTxOut{tyTxOutData=valueInState}} = onChainState
        logInfo @String $ "VidBid contract found in state: " ++ show valueInState
    Nothing -> logError @String $ "Couldn't find state of contract."

-- | The schema of the contract. It consists of the two endpoints @"lock"@
--   and @"guess"@ with their respective argument types.
type VidBIdStateMachineSchema =
        Endpoint "init" InitArgs
        .\/ Endpoint "lookup" ()
        .\/ Endpoint "open" ()

contract :: ( AsContractError e
                 , AsSMContractError e
                 ) => Contract () VidBIdStateMachineSchema e ()
contract = do
    selectList [init, lookup, open] >> contract


