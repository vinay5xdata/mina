(* js_util.ml -- types and transformers for Javascript *)

open Js_of_ocaml
open Snark_params.Tick
open Mina_base
module Global_slot = Mina_numbers.Global_slot
module Memo = Signed_command_memo

let raise_js_error s =
  Js_error.(raise_ @@ of_error (new%js Js.error_constr (Js.string s)))

type string_js = Js.js_string Js.t

type keypair_js =
  < privateKey : string_js Js.readonly_prop
  ; publicKey : string_js Js.readonly_prop >
  Js.t

type payload_common_js =
  < fee : string_js Js.prop
  ; feePayer : string_js Js.prop
  ; nonce : string_js Js.prop
  ; validUntil : string_js Js.prop
  ; memo : string_js Js.prop >
  Js.t

type payload_fee_payer_party_js =
  < fee : string_js Js.prop
  ; feePayer : string_js Js.prop
  ; nonce : string_js Js.prop
  ; memo : string_js Js.prop >
  Js.t

let payload_of_fee_payer_party_js
    (fee_payer_party_js : payload_fee_payer_party_js) : Party.Fee_payer.t =
  let fee_payer_pk =
    fee_payer_party_js##.feePayer
    |> Js.to_string |> Signature_lib.Public_key.of_base58_check_decompress_exn
  in
  let fee =
    fee_payer_party_js##.fee |> Js.to_string |> Currency.Fee.of_string
  in
  let nonce =
    fee_payer_party_js##.nonce |> Js.to_string
    |> Mina_numbers.Account_nonce.of_string
  in
  { Party.Fee_payer.body =
      { public_key = fee_payer_pk; fee; valid_until = None; nonce }
  ; authorization = Signature.dummy
  }

let payload_common_of_js (payload_common_js : payload_common_js) =
  let fee_js = payload_common_js##.fee in
  let fee = Js.to_string fee_js |> Currency.Fee.of_string in
  let fee_payer_pk =
    payload_common_js##.feePayer
    |> Js.to_string |> Signature_lib.Public_key.of_base58_check_decompress_exn
  in
  let nonce_js = payload_common_js##.nonce in
  let nonce = Js.to_string nonce_js |> Mina_numbers.Account_nonce.of_string in
  let valid_until_js = payload_common_js##.validUntil in
  let valid_until = Js.to_string valid_until_js |> Global_slot.of_string in
  let memo_js = payload_common_js##.memo in
  let memo = Js.to_string memo_js |> Memo.create_from_string_exn in
  Signed_command_payload.Common.Poly.
    { fee; fee_payer_pk; nonce; valid_until; memo }

type payment_payload_js =
  < source : string_js Js.prop
  ; receiver : string_js Js.prop
  ; amount : string_js Js.prop >
  Js.t

type payment_js =
  < common : payload_common_js Js.prop
  ; paymentPayload : payment_payload_js Js.prop >
  Js.t

let payment_body_of_js payment_payload =
  let source_pk =
    payment_payload##.source |> Js.to_string
    |> Signature_lib.Public_key.of_base58_check_decompress_exn
  in
  let receiver_pk =
    payment_payload##.receiver |> Js.to_string
    |> Signature_lib.Public_key.of_base58_check_decompress_exn
  in
  let amount =
    payment_payload##.amount |> Js.to_string |> Currency.Amount.of_string
  in
  Signed_command_payload.Body.Payment
    Payment_payload.Poly.{ source_pk; receiver_pk; amount }

let payload_of_payment_js payment_js : Signed_command_payload.t =
  let common = payload_common_of_js payment_js##.common in
  let body = payment_body_of_js payment_js##.paymentPayload in
  Signed_command_payload.Poly.{ common; body }

type stake_delegation_payload_js =
  < delegator : string_js Js.prop ; newDelegate : string_js Js.prop > Js.t

type stake_delegation_js =
  < common : payload_common_js Js.prop
  ; delegationPayload : stake_delegation_payload_js Js.prop >
  Js.t

let stake_delegation_body_of_js delegation_payload =
  let delegator =
    Js.to_string delegation_payload##.delegator
    |> Signature_lib.Public_key.of_base58_check_decompress_exn
  in
  let new_delegate =
    Js.to_string delegation_payload##.newDelegate
    |> Signature_lib.Public_key.of_base58_check_decompress_exn
  in
  Signed_command_payload.Body.Stake_delegation
    (Set_delegate { delegator; new_delegate })

let payload_of_stake_delegation_js payment_js : Signed_command_payload.t =
  let common = payload_common_of_js payment_js##.common in
  let body = stake_delegation_body_of_js payment_js##.delegationPayload in
  Signed_command_payload.Poly.{ common; body }

type signature_js =
  < field : string_js Js.readonly_prop ; scalar : string_js Js.readonly_prop >
  Js.t

let signature_to_js_object ((field, scalar) : Signature.t) =
  object%js
    val field = Field.to_string field |> Js.string

    val scalar = Inner_curve.Scalar.to_string scalar |> Js.string
  end

let signature_of_js_object (signature_js : signature_js) : Signature.t =
  let field = signature_js##.field |> Js.to_string |> Field.of_string in
  let scalar =
    signature_js##.scalar |> Js.to_string |> Inner_curve.Scalar.of_string
  in
  (field, scalar)

type signed_string =
  < string : string_js Js.readonly_prop
  ; signer : string_js Js.readonly_prop
  ; signature : signature_js Js.readonly_prop >
  Js.t

type signed_payment =
  < payment : payment_js Js.readonly_prop
  ; sender : string_js Js.readonly_prop
  ; signature : signature_js Js.readonly_prop >
  Js.t

type signed_stake_delegation =
  < stakeDelegation : stake_delegation_js Js.readonly_prop
  ; sender : string_js Js.readonly_prop
  ; signature : signature_js Js.readonly_prop >
  Js.t

let signature_kind_of_string_js network_js fname : Mina_signature_kind.t =
  match Js.to_string network_js |> Base.String.lowercase with
  | "mainnet" ->
      Mainnet
  | "testnet" ->
      Testnet
  | s ->
      raise_js_error
        (Core_kernel.sprintf
           "%s: expected network to be mainnet or testnet, got: %s" fname s )
