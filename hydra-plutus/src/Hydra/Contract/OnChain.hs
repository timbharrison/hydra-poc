{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-specialize #-}

module Hydra.Contract.OnChain where

import Ledger
import PlutusTx.Prelude

import Data.Aeson (ToJSON)
import Ledger.Ada (lovelaceValueOf)
import Ledger.Constraints (checkScriptContext)
import Ledger.Constraints.TxConstraints (
  mustBeSignedBy,
  mustForgeCurrency,
  mustPayToOtherScript,
  mustPayToTheScript,
  mustProduceAtLeast,
  mustSpendAtLeast,
  mustSpendPubKeyOutput,
  mustSpendScriptOutput,
 )
import Ledger.Credential (Credential (..))
import Ledger.Typed.Scripts (ScriptType (..))
import Ledger.Value (TokenName (..))
import PlutusPrelude (Generic, (>=>))
import PlutusTx.AssocMap (Map)
import PlutusTx.IsData.Class (IsData (..))

import qualified Ledger.Typed.Scripts as Scripts
import qualified Ledger.Value as Value
import qualified PlutusTx
import qualified PlutusTx.AssocMap as Map

--
-- Head Parameters
--

data HeadParameters = HeadParameters
  { participants :: [PubKeyHash]
  , policyId :: MonetaryPolicyHash
  }

PlutusTx.makeLift ''HeadParameters

--
-- Hydra State-Machine
--

data State
  = Initial
  | Open [TxOut]
  | Final
  deriving stock (Generic, Show)
  deriving anyclass (ToJSON)

PlutusTx.makeLift ''State
PlutusTx.unstableMakeIsData ''State

data Transition
  = CollectCom
  | Abort
  deriving (Generic, Show)

PlutusTx.makeLift ''Transition
PlutusTx.unstableMakeIsData ''Transition

data Hydra
instance Scripts.ScriptType Hydra where
  type DatumType Hydra = State
  type RedeemerType Hydra = Transition

hydraValidator ::
  HeadParameters ->
  State ->
  Transition ->
  ScriptContext ->
  Bool
hydraValidator HeadParameters{participants, policyId} s i ctx =
  case (s, i) of
    (Initial, CollectCom) ->
      let collectComUtxos =
            snd <$> filterInputs (hasParticipationToken policyId) ctx
          committedOutputs =
            mapMaybe decodeCommit collectComUtxos
          newState =
            Open committedOutputs
          amountPaid =
            foldMap txOutValue collectComUtxos
       in and
            [ mustBeSignedByOneOf participants ctx
            , all (mustForwardParticipationToken ctx policyId) participants
            , checkScriptContext @(RedeemerType Hydra) @(DatumType Hydra)
                (mustPayToTheScript newState amountPaid)
                ctx
            ]
    (Initial, Abort) ->
      let newState =
            Final
          amountPaid =
            lovelaceValueOf 0
       in and
            [ mustBeSignedByOneOf participants ctx
            , all (mustBurnParticipationToken ctx policyId) participants
            , checkScriptContext @(RedeemerType Hydra) @(DatumType Hydra)
                (mustPayToTheScript newState amountPaid)
                ctx
            ]
    _ ->
      False
 where
  decodeCommit =
    txOutDatumHash
      >=> (`findDatum` scriptContextTxInfo ctx)
      >=> (fromData @(DatumType Commit) . getDatum)

{- ORMOLU_DISABLE -}
hydraScriptInstance
  :: HeadParameters
  -> Scripts.ScriptInstance Hydra
hydraScriptInstance params = Scripts.validator @Hydra
    ( $$(PlutusTx.compile [|| hydraValidator ||])
      `PlutusTx.applyCode` PlutusTx.liftCode params
    )
    $$(PlutusTx.compile [|| wrap ||])
    where
        wrap = Scripts.wrapValidator @(DatumType Hydra) @(RedeemerType Hydra)
{- ORMOLU_ENABLE -}

hydraValidatorHash :: HeadParameters -> ValidatorHash
hydraValidatorHash = Scripts.scriptHash . hydraScriptInstance
{-# INLINEABLE hydraValidatorHash #-}

--
-- Initial Validator
--

data Initial
instance Scripts.ScriptType Initial where
  type DatumType Initial = PubKeyHash
  type RedeemerType Initial = TxOutRef

-- | The Validator 'initial' ensures that the input is consumed by a commit or
-- an abort transaction.
initialValidator ::
  HeadParameters ->
  ValidatorHash ->
  ValidatorHash ->
  PubKeyHash ->
  TxOutRef ->
  ScriptContext ->
  Bool
initialValidator HeadParameters{policyId} hydraScript commitScript vk ref ctx =
  consumedByCommit || consumedByAbort
 where
  -- A commit transaction, identified by:
  --    (a) A signature that verifies as valid with verification key defined as datum
  --    (b) Spending a UTxO also referenced as redeemer.
  --    (c) Having the commit validator in its only output, with a valid
  --        participation token for the associated key, and the total value of the
  --        committed UTxO.
  consumedByCommit =
    case findUtxo ref ctx of
      Nothing ->
        False
      Just utxo ->
        let commitDatum = asDatum @(DatumType Commit) (snd utxo)
            commitValue = txOutValue (snd utxo) <> mkParticipationToken policyId vk
         in checkScriptContext @(RedeemerType Initial) @(DatumType Initial)
              ( mconcat
                  [ mustBeSignedBy vk
                  , mustSpendPubKeyOutput (fst utxo)
                  , mustPayToOtherScript commitScript commitDatum commitValue
                  ]
              )
              ctx

  consumedByAbort =
    mustRunContract hydraScript Abort ctx

{- ORMOLU_DISABLE -}
initialScriptInstance
  :: HeadParameters
  -> Scripts.ScriptInstance Initial
initialScriptInstance policyId = Scripts.validator @Initial
  ($$(PlutusTx.compile [|| initialValidator ||])
      `PlutusTx.applyCode` PlutusTx.liftCode policyId
      `PlutusTx.applyCode` PlutusTx.liftCode (hydraValidatorHash policyId)
      `PlutusTx.applyCode` PlutusTx.liftCode (commitValidatorHash policyId)
  )
  $$(PlutusTx.compile [|| wrap ||])
 where
  wrap = Scripts.wrapValidator @(DatumType Initial) @(RedeemerType Initial)
{- ORMOLU_ENABLE -}

--
-- Commit Validator
--

data Commit
instance Scripts.ScriptType Commit where
  type DatumType Commit = TxOut
  type RedeemerType Commit = ()

-- |  To lock outputs for a Hydra head, the ith head member will attach a commit
-- transaction to the i-th output of the initial transaction.
-- Validator 'commit' ensures that the commit transaction correctly records the
-- partial UTxO set Ui committed by the party.
--
-- The data field of the output of the commit transaction is
--
--     Ui = makeUTxO(o_1 , . . . , o_m),
--
-- where the o_j are the outputs referenced by the commit transaction’s inputs
-- and makeUTxO stores pairs (out-ref_j , o_j) of outputs o_j with the
-- corresponding output reference out-ref_j .
commitValidator ::
  ValidatorHash ->
  TxOut ->
  () ->
  ScriptContext ->
  Bool
commitValidator hydraScript committedOut () ctx =
  consumedByCollectCom || consumedByAbort
 where
  consumedByCollectCom =
    mustRunContract hydraScript CollectCom ctx

  consumedByAbort =
    and
      [ mustRunContract hydraScript Abort ctx
      , mustReimburse committedOut ctx
      ]

{- ORMOLU_DISABLE -}
commitScriptInstance
  :: HeadParameters
  -> Scripts.ScriptInstance Commit
commitScriptInstance params = Scripts.validator @Commit
  ($$(PlutusTx.compile [|| commitValidator ||])
    `PlutusTx.applyCode` PlutusTx.liftCode (hydraValidatorHash params)
  )
  $$(PlutusTx.compile [|| wrap ||])
 where
  wrap = Scripts.wrapValidator @(DatumType Commit) @(RedeemerType Commit)
{- ORMOLU_ENABLE -}

commitValidatorHash :: HeadParameters -> ValidatorHash
commitValidatorHash = Scripts.scriptHash . commitScriptInstance
{-# INLINEABLE commitValidatorHash #-}

--
-- Monetary Policy
--

-- For the sake of simplicity in testing and whatnot, we currently 'fake' the
-- currencyId with an Integer chosen by a fair dice roll. In practice, we really
-- want this to a 'TxOutRef' so we can get actual guarantees from the ledger
-- about this being unique.
type CurrencyId = Integer

-- The validator is parameterized by the public keys of the participants, as well
-- as a reference to a particular UTxO. A minting transaction will be considered
-- valid if it is able to spend that UTxO (automatically ensuring that minting
-- can only happen *once*).
--
-- What it not necessarily transparent here is that, the on-chain code is really
-- made of the curried function 'ScriptContext -> Bool', after the first parameter
-- has been partially applied. This is similar to what is called 'closures' in
-- some languages. Fundamentally, the parameter 'CurrencyId' is embedded within the
-- policy and is part of the on-chain code itself!
validateMonetaryPolicy ::
  CurrencyId ->
  ScriptContext ->
  Bool
validateMonetaryPolicy _outRef _ctx =
  validateMinting || validateBurning
 where
  -- FIXME
  validateBurning =
    True

  -- TODO: In practice, we would do:
  --
  --     let constraints = mustSpendPubKeyOutput outRef
  --      in checkScriptContext @() @() constraints ctx
  validateMinting =
    True

hydraMonetaryPolicy ::
  CurrencyId ->
  MonetaryPolicy
hydraMonetaryPolicy outRef =
  mkMonetaryPolicyScript $
    $$(PlutusTx.compile [||Scripts.wrapMonetaryPolicy . validateMonetaryPolicy||])
      `PlutusTx.applyCode` PlutusTx.liftCode outRef

--
-- Helpers
--

-- | This function can be rather unsafe and should *always* be used with a type
-- annotation to avoid silly mistakes and hours of debugging.
--
-- So prefer:
--
-- >>> asDatum @(DatumType MyContract) val
--
-- over
--
-- >>> asDatum val
--
-- A 'Datum' is an opaque type, and type information is lost when turning into a
-- a 'Data'. Hence, various functions of the Plutus Tx framework that rely on
-- 'Datum' or 'Redeemer' are basically stringly-typed function with no guarantee
-- whatsoever that the 'IsData a' being passed will correspond to what's
-- expected by the underlying script. So, save you some hours of debugging and
-- always explicitly specify the source type when using this function,
-- preferably using the data-family from the 'ScriptType' instance.
asDatum :: IsData a => a -> Datum
asDatum = Datum . toData
{-# INLINEABLE asDatum #-}

-- | Always use with explicit type-annotation, See warnings on 'asDatum'.
asRedeemer :: IsData a => a -> Redeemer
asRedeemer = Redeemer . toData
{-# INLINEABLE asRedeemer #-}

mustBeSignedByOneOf ::
  [PubKeyHash] ->
  ScriptContext ->
  Bool
mustBeSignedByOneOf vks ctx =
  or ((`checkScriptContext` ctx) . mustBeSignedBy @() @() <$> vks)
{-# INLINEABLE mustBeSignedByOneOf #-}

mustReimburse ::
  TxOut ->
  ScriptContext ->
  Bool
mustReimburse txOut =
  elem txOut . txInfoOutputs . scriptContextTxInfo
{-# INLINEABLE mustReimburse #-}

mustRunContract ::
  forall redeemer.
  (IsData redeemer) =>
  ValidatorHash ->
  redeemer ->
  ScriptContext ->
  Bool
mustRunContract script redeemer ctx =
  case findContractInput script ctx of
    Nothing ->
      False
    Just contractRef ->
      checkScriptContext @() @()
        ( mconcat
            [ mustSpendScriptOutput contractRef (asRedeemer redeemer)
            ]
        )
        ctx
{-# INLINEABLE mustRunContract #-}

mustForwardParticipationToken ::
  ScriptContext ->
  MonetaryPolicyHash ->
  PubKeyHash ->
  Bool
mustForwardParticipationToken ctx policyId vk =
  let participationToken = mkParticipationToken policyId vk
   in checkScriptContext @() @()
        ( mconcat
            [ mustSpendAtLeast participationToken
            , mustProduceAtLeast participationToken
            ]
        )
        ctx
{-# INLINEABLE mustForwardParticipationToken #-}

mustBurnParticipationToken ::
  ScriptContext ->
  MonetaryPolicyHash ->
  PubKeyHash ->
  Bool
mustBurnParticipationToken ctx policyId vk =
  let assetName = mkParticipationTokenName vk
   in checkScriptContext @() @() (mustForgeCurrency policyId assetName (-1)) ctx
{-# INLINEABLE mustBurnParticipationToken #-}

mkParticipationToken ::
  MonetaryPolicyHash ->
  PubKeyHash ->
  Value
mkParticipationToken policyId vk =
  Value.singleton (Value.mpsSymbol policyId) (mkParticipationTokenName vk) 1
{-# INLINEABLE mkParticipationToken #-}

mkParticipationTokenName ::
  PubKeyHash ->
  TokenName
mkParticipationTokenName =
  TokenName . getPubKeyHash
{-# INLINEABLE mkParticipationTokenName #-}

hasParticipationToken :: MonetaryPolicyHash -> TxInInfo -> Bool
hasParticipationToken policyId input =
  let currency = Value.mpsSymbol policyId
   in currency `elem` symbols (txOutValue $ txInInfoResolved input)
{-# INLINEABLE hasParticipationToken #-}

filterInputs :: (TxInInfo -> Bool) -> ScriptContext -> [(TxOutRef, TxOut)]
filterInputs predicate =
  mapMaybe fn . txInfoInputs . scriptContextTxInfo
 where
  fn info
    | predicate info = Just (txInInfoOutRef info, txInInfoResolved info)
    | otherwise = Nothing
{-# INLINEABLE filterInputs #-}

findUtxo :: TxOutRef -> ScriptContext -> Maybe (TxOutRef, TxOut)
findUtxo ref ctx =
  case filterInputs (\input -> ref == txInInfoOutRef input) ctx of
    [utxo] -> Just utxo
    _ -> Nothing
{-# INLINEABLE findUtxo #-}

findContractInput :: ValidatorHash -> ScriptContext -> Maybe TxOutRef
findContractInput script ctx =
  case filterInputs (matchScript . txInInfoResolved) ctx of
    [utxo] -> Just (fst utxo)
    _ -> Nothing
 where
  matchScript :: TxOut -> Bool
  matchScript txOut =
    case txOutAddress txOut of
      Address (ScriptCredential script') _ -> script == script'
      _ -> False
{-# INLINEABLE findContractInput #-}

-- NOTE: Not using `Value.symbols` because it is broken. In fact, a 'Value' may
-- carry null quantities of some particular tokens, leading to weird situation
-- where both:
--
--   - value == lovelaceValueOf n
--   - symbols value /= [adaSymbol]
--
-- are true at the same time. The equality makes no difference between the
-- absence of a certain symbol/token, and a null quantity of that symbol. Such
-- null quantities are probably constructed when moving values around but they
-- don't really mean anything so they should be discarded from views of the
-- value itself, like 'symbols'
symbols :: Value -> [CurrencySymbol]
symbols = foldr normalize [] . Map.toList . Value.getValue
 where
  normalize :: (CurrencySymbol, Map TokenName Integer) -> [CurrencySymbol] -> [CurrencySymbol]
  normalize (currency, tokens) acc
    | currency `elem` acc = acc
    | otherwise =
      let elems = snd <$> Map.toList tokens
       in if sum elems == 0 then acc else currency : acc
{-# INLINEABLE symbols #-}
