(* See the .mli for a description of the purpose of this module. *)
open Core
open Mina_base
open Mina_transaction
open Mina_numbers
open Signature_lib

(* Fee increase required to replace a transaction. *)
let replace_fee : Currency.Fee.t = Currency.Fee.of_int 1

(* Invariants, maintained whenever a t is exposed from this module:
   * Iff a command is in all_by_fee it is also in all_by_sender.
   * Iff a command is in all_by_fee it is also in all_by_hash.
   * Iff a command is at the head of its sender's queue it is also in
     applicable_by_fee.
   * Sequences in all_by_sender are ordered by nonce and "dense".
   * Only commands with an expiration <> Global_slot.max_value is added to transactions_with_expiration.
   * There are no empty sets or sequences.
   * Fee indices are correct.
   * Total currency required is correct.
   * size = the sum of sizes of the sets in all_by_fee = the sum of the lengths
     of the queues in all_by_sender
*)

module Config = struct
  type t =
    { constraint_constants : Genesis_constants.Constraint_constants.t
    ; consensus_constants : Consensus.Constants.t
    ; time_controller : Block_time.Controller.t
    ; expiry_ns : Time_ns.Span.t
          (* Discard transactions after the expiry duration has elapsed,
             and do not accept transactions that cannot become includable
             before the expiry duration has elapsed.
             Default value as in Bitcoin ('mempoolexpiry').
             TODO: Make this configurable *)
    }
  [@@deriving sexp_of, equal, compare]
end

type t =
  { applicable_by_fee :
      Transaction_hash.User_command_with_valid_signature.Set.t
      Currency.Fee_rate.Map.t
        (** Transactions valid against the current ledger, indexed by fee per
            weight unit. *)
  ; all_by_sender :
      ( Transaction_hash.User_command_with_valid_signature.t F_sequence.t
      * Currency.Amount.t )
      Account_id.Map.t
        (** All pending transactions along with the total currency required to
            execute them -- plus any currency spent from this account by
            transactions from other accounts -- indexed by sender account.
            Ordered by nonce inside the accounts. *)
  ; all_by_fee :
      Transaction_hash.User_command_with_valid_signature.Set.t
      Currency.Fee_rate.Map.t
        (** All transactions in the pool indexed by fee per weight unit. *)
  ; all_by_hash :
      Transaction_hash.User_command_with_valid_signature.t
      Transaction_hash.Map.t
  ; transactions_with_expiration :
      Transaction_hash.User_command_with_valid_signature.Set.t Global_slot.Map.t
        (*Only transactions that have an expiry*)
  ; entry_times : Time_ns.t Transaction_hash.Map.t
        (** The entry time for each transaction *)
  ; all_by_entry_time : Transaction_hash.t Time_ns.Map.t
        (** All transactions in the pool indexed by their entry time *)
  ; size : int
  ; config : Config.t
  }
[@@deriving sexp_of, equal, compare]

let config t = t.config

module Command_error = struct
  (* IMPORTANT! Do not change the names of these errors as to adjust the
   * to_yojson output without updating Rosetta's construction API to handle the
   * changes *)
  type t =
    | Invalid_nonce of
        [ `Expected of Account.Nonce.t
        | `Between of Account.Nonce.t * Account.Nonce.t ]
        * Account.Nonce.t
    | Insufficient_funds of
        [ `Balance of Currency.Amount.t ] * Currency.Amount.t
    | (* NOTE: don't punish for this, attackers can induce nodes to banlist
          each other that way! *)
        Insufficient_replace_fee of
        [ `Replace_fee of Currency.Fee.t ] * Currency.Fee.t
    | Overflow
    | Bad_token
    | Expired of
        [ `Valid_until of Mina_numbers.Global_slot.t
        | `Timestamp_predicate of string ]
        * [ `Global_slot_since_genesis of Mina_numbers.Global_slot.t ]
    | Unwanted_fee_token of Token_id.t
    | Verification_failed
  [@@deriving sexp, to_yojson]

  let grounds_for_diff_rejection : t -> bool = function
    | Expired _
    | Invalid_nonce _
    | Insufficient_funds _
    | Insufficient_replace_fee _ ->
        false
    | Overflow | Bad_token | Unwanted_fee_token _ | Verification_failed ->
        true
end

(* Compute the total currency required from the sender to execute a command.
   Returns None in case of overflow.
*)
let currency_consumed_unchecked :
       constraint_constants:Genesis_constants.Constraint_constants.t
    -> User_command.t
    -> Currency.Amount.t option =
 fun ~constraint_constants:_ cmd ->
  let fee_amt = Currency.Amount.of_fee @@ User_command.fee cmd in
  let open Currency.Amount in
  let amt =
    match cmd with
    | Signed_command c -> (
        match c.payload.body with
        | Payment { amount; _ } ->
            (* The fee-payer is also the sender account, include the amount. *)
            amount
        | Stake_delegation _ ->
            zero )
    | Parties _ ->
        (*TODO: document- txns succeeds with source amount insufficient in the case of zkapps*)
        zero
  in
  fee_amt + amt

let currency_consumed ~constraint_constants cmd =
  currency_consumed_unchecked ~constraint_constants
    (Transaction_hash.User_command_with_valid_signature.command cmd)

let currency_consumed' :
       constraint_constants:Genesis_constants.Constraint_constants.t
    -> User_command.t
    -> (Currency.Amount.t, Command_error.t) Result.t =
 fun ~constraint_constants cmd ->
  cmd
  |> currency_consumed_unchecked ~constraint_constants
  |> Result.of_option ~error:Command_error.Overflow

module For_tests = struct
  (* Check the invariants of the pool structure as listed in the comment above.
  *)
  let assert_invariants : t -> unit =
   fun { applicable_by_fee
       ; all_by_sender
       ; all_by_fee
       ; all_by_hash
       ; size
       ; config = { constraint_constants; _ }
       ; _
       } ->
    let assert_all_by_fee tx =
      if
        Set.mem
          (Map.find_exn all_by_fee
             ( Transaction_hash.User_command_with_valid_signature.command tx
             |> User_command.fee_per_wu ) )
          tx
      then ()
      else
        failwith
        @@ sprintf
             !"Not found in all_by_fee: %{sexp: \
               Transaction_hash.User_command_with_valid_signature.t }"
             tx
    in
    let assert_all_by_hash tx =
      [%test_eq: Transaction_hash.User_command_with_valid_signature.t] tx
        (Map.find_exn all_by_hash
           (Transaction_hash.User_command_with_valid_signature.hash tx) )
    in
    Map.iteri applicable_by_fee ~f:(fun ~key ~data ->
        Set.iter data ~f:(fun tx ->
            let unchecked =
              Transaction_hash.User_command_with_valid_signature.command tx
            in
            [%test_eq: Currency.Fee_rate.t] key
              (User_command.fee_per_wu unchecked) ;
            let tx' =
              Map.find_exn all_by_sender (User_command.fee_payer unchecked)
              |> Tuple2.get1 |> F_sequence.head_exn
            in
            [%test_eq: Transaction_hash.User_command_with_valid_signature.t] tx
              tx' ;
            assert_all_by_fee tx ;
            assert_all_by_hash tx ) ) ;
    Map.iteri all_by_sender
      ~f:(fun ~key:fee_payer ~data:(tx_seq, currency_reserved) ->
        assert (F_sequence.length tx_seq > 0) ;
        let check_consistent tx =
          [%test_eq: Account_id.t]
            ( Transaction_hash.User_command_with_valid_signature.command tx
            |> User_command.fee_payer )
            fee_payer ;
          assert_all_by_fee tx ;
          assert_all_by_hash tx
        in
        let applicable, inapplicables =
          Option.value_exn (F_sequence.uncons tx_seq)
        in
        let applicable_unchecked =
          Transaction_hash.User_command_with_valid_signature.command applicable
        in
        check_consistent applicable ;
        assert (
          Set.mem
            (Map.find_exn applicable_by_fee
               (User_command.fee_per_wu applicable_unchecked) )
            applicable ) ;
        let _last_nonce, currency_reserved' =
          F_sequence.foldl
            (fun (curr_nonce, currency_acc) tx ->
              let unchecked =
                Transaction_hash.User_command_with_valid_signature.command tx
              in
              [%test_eq: Account_nonce.t]
                (User_command.applicable_at_nonce unchecked)
                curr_nonce ;
              check_consistent tx ;
              ( User_command.expected_target_nonce unchecked
              , Option.value_exn
                  Currency.Amount.(
                    Option.value_exn
                      (currency_consumed ~constraint_constants tx)
                    + currency_acc) ) )
            ( User_command.expected_target_nonce applicable_unchecked
            , Option.value_exn
                (currency_consumed ~constraint_constants applicable) )
            inapplicables
        in
        [%test_eq: Currency.Amount.t] currency_reserved currency_reserved' ) ;
    let check_sender_applicable fee tx =
      let unchecked =
        Transaction_hash.User_command_with_valid_signature.command tx
      in
      [%test_eq: Currency.Fee.t] fee (User_command.fee unchecked) ;
      let sender_txs, _currency_reserved =
        Map.find_exn all_by_sender (User_command.fee_payer unchecked)
      in
      let applicable, _inapplicables =
        Option.value_exn (F_sequence.uncons sender_txs)
      in
      assert (
        Set.mem
          (Map.find_exn applicable_by_fee
             ( applicable
             |> Transaction_hash.User_command_with_valid_signature.command
             |> User_command.fee_per_wu ) )
          applicable ) ;
      let tx' =
        F_sequence.find sender_txs ~f:(fun cmd ->
            let applicable_at_nonce =
              cmd |> Transaction_hash.User_command_with_valid_signature.command
              |> User_command.applicable_at_nonce
            in
            Account_nonce.equal applicable_at_nonce
            @@ User_command.applicable_at_nonce unchecked )
        |> Option.value_exn
      in
      [%test_eq: Transaction_hash.User_command_with_valid_signature.t] tx tx'
    in
    Map.iteri all_by_fee ~f:(fun ~key:fee_per_wu ~data:tx_set ->
        Set.iter tx_set ~f:(fun tx ->
            let command =
              Transaction_hash.User_command_with_valid_signature.command tx
            in
            let wu = User_command.weight command in
            let fee =
              Currency.Fee_rate.scale_exn fee_per_wu wu
              |> Currency.Fee_rate.to_uint64_exn |> Currency.Fee.of_uint64
            in
            check_sender_applicable fee tx ;
            assert_all_by_hash tx ) ) ;
    Map.iter all_by_hash ~f:(fun tx ->
        check_sender_applicable
          (User_command.fee
             (Transaction_hash.User_command_with_valid_signature.command tx) )
          tx ;
        assert_all_by_fee tx ) ;
    [%test_eq: int] (Map.length all_by_hash) size
end

let empty ~constraint_constants ~consensus_constants ~time_controller ~expiry_ns
    : t =
  { applicable_by_fee = Currency.Fee_rate.Map.empty
  ; all_by_sender = Account_id.Map.empty
  ; all_by_fee = Currency.Fee_rate.Map.empty
  ; all_by_hash = Transaction_hash.Map.empty
  ; entry_times = Transaction_hash.Map.empty
  ; all_by_entry_time = Time_ns.Map.empty
  ; transactions_with_expiration = Global_slot.Map.empty
  ; size = 0
  ; config =
      { constraint_constants; consensus_constants; time_controller; expiry_ns }
  }

let size : t -> int = fun t -> t.size

(* The least fee per weight unit of all transactions in the transaction pool *)
let min_fee : t -> Currency.Fee_rate.t option =
 fun { all_by_fee; _ } -> Option.map ~f:Tuple2.get1 @@ Map.min_elt all_by_fee

let member : t -> Transaction_hash.User_command.t -> bool =
 fun t cmd ->
  Option.is_some
    (Map.find t.all_by_hash (Transaction_hash.User_command.hash cmd))

let all_from_account :
       t
    -> Account_id.t
    -> Transaction_hash.User_command_with_valid_signature.t list =
 fun { all_by_sender; _ } account_id ->
  Option.value_map ~default:[] (Map.find all_by_sender account_id)
    ~f:(fun (user_commands, _) -> F_sequence.to_list user_commands)

let get_all { all_by_hash; _ } :
    Transaction_hash.User_command_with_valid_signature.t list =
  Map.data all_by_hash

let find_by_hash :
       t
    -> Transaction_hash.t
    -> Transaction_hash.User_command_with_valid_signature.t option =
 fun { all_by_hash; _ } hash -> Map.find all_by_hash hash

let global_slot_since_genesis conf =
  let current_time = Block_time.now conf.Config.time_controller in
  let current_slot =
    Consensus.Data.Consensus_time.(
      of_time_exn ~constants:conf.consensus_constants current_time
      |> to_global_slot)
  in
  match conf.constraint_constants.fork with
  | Some { previous_global_slot; _ } ->
      Mina_numbers.Global_slot.(add previous_global_slot current_slot)
  | None ->
      current_slot

let check_expiry t (cmd : User_command.t) =
  let global_slot_since_genesis = global_slot_since_genesis t in
  let valid_until = User_command.valid_until cmd in
  if Global_slot.(valid_until < global_slot_since_genesis) then
    Error
      (Command_error.Expired
         ( `Valid_until valid_until
         , `Global_slot_since_genesis global_slot_since_genesis ) )
  else Ok ()

(* a cmd is in the transactions_with_expiration map only if it has an expiry*)
let update_expiration_map expiration_map cmd op =
  let user_cmd =
    Transaction_hash.User_command_with_valid_signature.command cmd
  in
  let expiry = User_command.valid_until user_cmd in
  if Global_slot.(expiry <> max_value) then
    match op with
    | `Add ->
        Map_set.insert
          (module Transaction_hash.User_command_with_valid_signature)
          expiration_map expiry cmd
    | `Del ->
        Map_set.remove_exn expiration_map expiry cmd
  else expiration_map

let remove_from_expiration_exn expiration_map cmd =
  update_expiration_map expiration_map cmd `Del

let add_to_expiration expiration_map cmd =
  update_expiration_map expiration_map cmd `Add

(* Remove a command from the applicable_by_fee field. This may break an
   invariant. *)
let remove_applicable_exn :
    t -> Transaction_hash.User_command_with_valid_signature.t -> t =
 fun t cmd ->
  let fee_per_wu =
    Transaction_hash.User_command_with_valid_signature.command cmd
    |> User_command.fee_per_wu
  in
  { t with
    applicable_by_fee = Map_set.remove_exn t.applicable_by_fee fee_per_wu cmd
  }

(* Remove a command from entry_times and all_by_entry_time *)
let remove_entry_times (cmd_hash : Transaction_hash.t) (t : t) : t =
  let entry_time = Map.find t.entry_times cmd_hash in
  match entry_time with
  | Some entry_time ->
      { t with
        entry_times = Map.remove t.entry_times cmd_hash
      ; all_by_entry_time = Map.remove t.all_by_entry_time entry_time
      }
  | None ->
      failwithf "Entry time not found for command hash %s"
        (Transaction_hash.to_base58_check cmd_hash)
        ()

(* Reset entry_times and all_by_entry_time for a command *)
let reset_entry_times (cmd_hash : Transaction_hash.t) (t : t) : t =
  let entry_time = Time_ns.now () in
  { t with
    entry_times = Map.update t.entry_times cmd_hash ~f:(fun _ -> entry_time)
  ; all_by_entry_time =
      Map.update t.all_by_entry_time entry_time ~f:(fun _ -> cmd_hash)
  }

(* Remove a command from the all_by_fee and all_by_hash fields, and decrement
   size. This may break an invariant. *)
let remove_all_by_fee_and_hash_and_expiration_exn :
    t -> Transaction_hash.User_command_with_valid_signature.t -> t =
 fun t cmd ->
  let fee_per_wu =
    Transaction_hash.User_command_with_valid_signature.command cmd
    |> User_command.fee_per_wu
  in
  let cmd_hash = Transaction_hash.User_command_with_valid_signature.hash cmd in
  { t with
    all_by_fee = Map_set.remove_exn t.all_by_fee fee_per_wu cmd
  ; all_by_hash = Map.remove t.all_by_hash cmd_hash
  ; transactions_with_expiration =
      remove_from_expiration_exn t.transactions_with_expiration cmd
  ; size = t.size - 1
  }
  |> remove_entry_times cmd_hash

module Sender_local_state = struct
  type t0 =
    { sender : Account_id.t
    ; data :
        ( Transaction_hash.User_command_with_valid_signature.t F_sequence.t
        * Currency.Amount.t )
        option
    }

  type t = (t0[@sexp.opaque]) [@@deriving sexp]

  let sender { sender; _ } = sender

  let to_yojson _ = `String "<per_sender>"

  let is_remove t = Option.is_none t.data
end

let set_sender_local_state (t : t) ({ sender; data } : Sender_local_state.t) : t
    =
  { t with
    all_by_sender = Map.change t.all_by_sender sender ~f:(fun _ -> data)
  }

let get_sender_local_state (t : t) sender : Sender_local_state.t =
  { sender; data = Map.find t.all_by_sender sender }

module Update = struct
  module F_seq = struct
    type 'a t = 'a F_sequence.t

    include
      Sexpable.Of_sexpable1
        (List)
        (struct
          type 'a t = 'a F_sequence.t

          let to_sexpable = F_sequence.to_list

          let of_sexpable xs =
            List.fold xs ~init:F_sequence.empty ~f:F_sequence.snoc
        end)
  end

  type single =
    | Add of
        { command : Transaction_hash.User_command_with_valid_signature.t
        ; fee_per_wu : Currency.Fee_rate.t
        ; add_to_applicable_by_fee : bool
        }
    | Remove_all_by_fee_and_hash_and_expiration of
        Transaction_hash.User_command_with_valid_signature.t F_seq.t
    | Remove_from_applicable_by_fee of
        { fee_per_wu : Currency.Fee_rate.t
        ; command : Transaction_hash.User_command_with_valid_signature.t
        }
  [@@deriving sexp]

  type t = single Writer_result.Tree.t (* [@sexp.opaque] *) [@@deriving sexp]

  let to_yojson _ = `String "<update>"

  let apply acc (u : single) =
    match u with
    | Add { command = cmd; fee_per_wu; add_to_applicable_by_fee } ->
        let acc =
          if add_to_applicable_by_fee then
            { acc with
              applicable_by_fee =
                Map_set.insert
                  (module Transaction_hash.User_command_with_valid_signature)
                  acc.applicable_by_fee fee_per_wu cmd
            }
          else acc
        in
        let cmd_hash =
          Transaction_hash.User_command_with_valid_signature.hash cmd
        in
        { acc with
          all_by_fee =
            Map_set.insert
              (module Transaction_hash.User_command_with_valid_signature)
              acc.all_by_fee fee_per_wu cmd
        ; all_by_hash = Map.set acc.all_by_hash ~key:cmd_hash ~data:cmd
        ; transactions_with_expiration =
            add_to_expiration acc.transactions_with_expiration cmd
        ; size = acc.size + 1
        }
        |> reset_entry_times cmd_hash
    | Remove_all_by_fee_and_hash_and_expiration cmds ->
        F_sequence.foldl
          (fun acc cmd -> remove_all_by_fee_and_hash_and_expiration_exn acc cmd)
          acc cmds
    | Remove_from_applicable_by_fee { fee_per_wu; command } ->
        { acc with
          applicable_by_fee =
            Map_set.remove_exn acc.applicable_by_fee fee_per_wu command
        }

  let apply (us : t) t = Writer_result.Tree.fold ~init:t us ~f:apply

  let merge (t1 : t) (t2 : t) = Writer_result.Tree.append t1 t2

  let empty : t = Empty
end

let run :
    type a e.
       sender:Account_id.t
    -> t
    -> (Sender_local_state.t ref -> (a, Update.single, e) Writer_result.t)
    -> (a * t, e) Result.t =
 fun ~sender t a ->
  let r = ref (get_sender_local_state t sender) in
  let res = Writer_result.run (a r) in
  Result.map res ~f:(fun (a, updates) ->
      let t = set_sender_local_state t !r in
      (a, Update.apply updates t) )

(* Remove a given command from the pool, as well as any commands that depend on
   it. Called from revalidate and remove_lowest_fee, and when replacing
   transactions. *)
let remove_with_dependents_exn :
       constraint_constants:_
    -> Transaction_hash.User_command_with_valid_signature.t
    -> Sender_local_state.t ref
    -> ( Transaction_hash.User_command_with_valid_signature.t Sequence.t
       , Update.single
       , _ )
       Writer_result.t =
 fun ~constraint_constants (* ({ constraint_constants; _ } as t) *) cmd state ->
  let unchecked =
    Transaction_hash.User_command_with_valid_signature.command cmd
  in
  let open Writer_result.Let_syntax in
  let sender_queue, reserved_currency = Option.value_exn !state.data in
  assert (not @@ F_sequence.is_empty sender_queue) ;
  let cmd_nonce =
    Transaction_hash.User_command_with_valid_signature.command cmd
    |> User_command.applicable_at_nonce
  in
  let cmd_index =
    F_sequence.findi sender_queue ~f:(fun cmd' ->
        let nonce =
          Transaction_hash.User_command_with_valid_signature.command cmd'
          |> User_command.applicable_at_nonce
        in
        (* we just compare nonce equality since the command we are looking for already exists in the sequence *)
        Account_nonce.equal nonce cmd_nonce )
    |> Option.value_exn
  in
  let keep_queue, drop_queue = F_sequence.split_at sender_queue cmd_index in
  assert (not (F_sequence.is_empty drop_queue)) ;
  let currency_to_remove =
    F_sequence.foldl
      (fun acc cmd' ->
        Option.value_exn
          (* safe because we check for overflow when we add commands. *)
          (let open Option.Let_syntax in
          let%bind consumed = currency_consumed ~constraint_constants cmd' in
          Currency.Amount.(consumed + acc)) )
      Currency.Amount.zero drop_queue
  in
  let reserved_currency' =
    (* This is safe because the currency in a subset of the commands much be <=
       total currency in all the commands. *)
    Option.value_exn Currency.Amount.(reserved_currency - currency_to_remove)
  in
  let%map () =
    Writer_result.write
      (Update.Remove_all_by_fee_and_hash_and_expiration drop_queue)
  and () =
    if cmd_index = 0 then
      Writer_result.write
        (Update.Remove_from_applicable_by_fee
           { fee_per_wu = User_command.fee_per_wu unchecked; command = cmd } )
    else Writer_result.return ()
  in
  state :=
    { !state with
      data =
        ( if not (F_sequence.is_empty keep_queue) then
          Some (keep_queue, reserved_currency')
        else (
          assert (Currency.Amount.(equal reserved_currency' zero)) ;
          None ) )
    } ;
  F_sequence.to_seq drop_queue

let run' t cmd x =
  run t
    ~sender:
      (User_command.fee_payer
         (Transaction_hash.User_command_with_valid_signature.command cmd) )
    x

let remove_with_dependents_exn' t cmd =
  match
    run' t cmd
      (remove_with_dependents_exn
         ~constraint_constants:t.config.constraint_constants cmd )
  with
  | Ok x ->
      x
  | Error _ ->
      failwith "remove_with_dependents_exn"

(** Drop commands from the end of the queue until the total currency consumed is
    <= the current balance. *)
let drop_until_sufficient_balance :
       constraint_constants:Genesis_constants.Constraint_constants.t
    -> Transaction_hash.User_command_with_valid_signature.t F_sequence.t
       * Currency.Amount.t
    -> Currency.Amount.t
    -> Transaction_hash.User_command_with_valid_signature.t F_sequence.t
       * Currency.Amount.t
       * Transaction_hash.User_command_with_valid_signature.t Sequence.t =
 fun ~constraint_constants (queue, currency_reserved) current_balance ->
  let rec go queue' currency_reserved' dropped_so_far =
    if Currency.Amount.(currency_reserved' <= current_balance) then
      (queue', currency_reserved', dropped_so_far)
    else
      let daeh, liat =
        Option.value_exn
          ~message:
            "couldn't drop any more transactions when trying to preserve \
             sufficient balance"
          (F_sequence.unsnoc queue')
      in
      let consumed =
        Option.value_exn (currency_consumed ~constraint_constants liat)
      in
      go daeh
        (Option.value_exn Currency.Amount.(currency_reserved' - consumed))
        (Sequence.append dropped_so_far @@ Sequence.singleton liat)
  in
  go queue currency_reserved Sequence.empty

(* Iterate over all commands in the pool, removing them if they require too much
   currency or have too low of a nonce.
*)
let revalidate :
       t
    -> (Account_id.t -> Account_nonce.t * Currency.Amount.t)
    -> t * Transaction_hash.User_command_with_valid_signature.t Sequence.t =
 fun ({ config = { constraint_constants; _ }; _ } as t) f ->
  Map.fold t.all_by_sender ~init:(t, Sequence.empty)
    ~f:(fun
         ~key:sender
         ~data:(queue, currency_reserved)
         ((t', dropped_acc) as acc)
       ->
      let current_nonce, current_balance = f sender in
      let first_cmd = F_sequence.head_exn queue in
      let first_nonce =
        first_cmd |> Transaction_hash.User_command_with_valid_signature.command
        |> User_command.applicable_at_nonce
      in
      if Account_nonce.(current_nonce < first_nonce) then
        let dropped, t'' = remove_with_dependents_exn' t first_cmd in
        (t'', Sequence.append dropped_acc dropped)
      else
        (* current_nonce >= first_nonce *)
        let first_applicable_nonce_index =
          F_sequence.findi queue ~f:(fun cmd' ->
              let nonce =
                Transaction_hash.User_command_with_valid_signature.command cmd'
                |> User_command.applicable_at_nonce
              in
              Account_nonce.equal nonce current_nonce )
          |> Option.value ~default:(F_sequence.length queue)
        in
        let drop_queue, keep_queue =
          F_sequence.split_at queue first_applicable_nonce_index
        in
        let currency_reserved' =
          F_sequence.foldl
            (fun c cmd ->
              Option.value_exn
                Currency.Amount.(
                  c
                  - Option.value_exn
                      (currency_consumed ~constraint_constants cmd)) )
            currency_reserved drop_queue
        in
        let keep_queue', currency_reserved'', dropped_for_balance =
          drop_until_sufficient_balance ~constraint_constants
            (keep_queue, currency_reserved')
            current_balance
        in
        let to_drop =
          Sequence.append (F_sequence.to_seq drop_queue) dropped_for_balance
        in
        match Sequence.next to_drop with
        | None ->
            acc
        | Some (head, tail) ->
            let t'' =
              Sequence.fold tail
                ~init:
                  (remove_all_by_fee_and_hash_and_expiration_exn
                     (remove_applicable_exn t' head)
                     head )
                ~f:remove_all_by_fee_and_hash_and_expiration_exn
            in
            ( { t'' with
                all_by_sender =
                  Map.set t''.all_by_sender ~key:sender
                    ~data:(keep_queue', currency_reserved'')
              }
            , Sequence.append dropped_acc to_drop ) )

let expired_by_predicate (t : t) :
    Transaction_hash.User_command_with_valid_signature.t Sequence.t =
  let time_now = Time_ns.now () in
  let expiry_time = Time_ns.(sub time_now t.config.expiry_ns) in
  Map.to_sequence t.all_by_hash
  |> Sequence.filter_map ~f:(fun (cmd_hash, cmd) ->
         Transaction_hash.User_command_with_valid_signature.data cmd
         |> function
         | User_command.Parties (ps : Parties.Valid.t) ->
             Some (cmd_hash, ps.parties)
         | User_command.Signed_command _ ->
             None )
  |> Sequence.filter ~f:(fun (_, ps) ->
         ps.other_parties
         |> Parties.Call_forest.exists ~f:(fun party ->
                let predicate = Party.protocol_state_precondition party in
                match predicate.timestamp with
                | Check { upper; _ } ->
                    Block_time.(upper < of_time_ns expiry_time)
                | _ ->
                    false ) )
  |> Sequence.map ~f:fst
  |> Sequence.map ~f:(Map.find_exn t.all_by_hash)

let expired_by_age (t : t) :
    Transaction_hash.User_command_with_valid_signature.t Sequence.t =
  let time_now = Time_ns.now () in
  let expiry_time = Time_ns.(sub time_now t.config.expiry_ns) in
  let expired, _, _ = Map.split t.all_by_entry_time expiry_time in
  Map.to_sequence expired
  |> Sequence.map ~f:(fun (_, cmd_hash) -> Map.find_exn t.all_by_hash cmd_hash)

let expired_by_global_slot (t : t) :
    Transaction_hash.User_command_with_valid_signature.t Sequence.t =
  let global_slot_since_genesis = global_slot_since_genesis t.config in
  let expired, _, _ =
    Map.split t.transactions_with_expiration global_slot_since_genesis
  in
  Map.to_sequence expired |> Sequence.map ~f:snd
  |> Sequence.bind ~f:Set.to_sequence

let expired (t : t) :
    Transaction_hash.User_command_with_valid_signature.t Sequence.t =
  [ expired_by_predicate t; expired_by_age t; expired_by_global_slot t ]
  |> Sequence.of_list |> Sequence.concat

let remove_expired t :
    Transaction_hash.User_command_with_valid_signature.t Sequence.t * t =
  Sequence.fold (expired t) ~init:(Sequence.empty, t) ~f:(fun acc cmd ->
      let dropped_acc, t = acc in
      (*[cmd] would not be in [t] if it depended on an expired transaction already handled*)
      if member t (Transaction_hash.User_command.of_checked cmd) then
        let removed, t' = remove_with_dependents_exn' t cmd in
        (Sequence.append dropped_acc removed, t')
      else acc )

let actual_target_nonce cmd ~application_status =
  match cmd with
  | User_command.Signed_command x ->
      Account.Nonce.succ (Signed_command.nonce x)
  | Parties p -> (
      match application_status with
      | None | Some (Transaction_status.Failed _) ->
          User_command.expected_target_nonce cmd
      | _ ->
          Parties.target_nonce_on_success p )

let handle_committed_txn :
       t
    -> Transaction_hash.User_command_with_valid_signature.t
    -> application_status:Transaction_status.t option
    -> fee_payer_balance:Currency.Amount.t
    -> fee_payer_nonce:Mina_base.Account.Nonce.t
    -> ( t * Transaction_hash.User_command_with_valid_signature.t Sequence.t
       , [ `Queued_txns_by_sender of
           string
           * Transaction_hash.User_command_with_valid_signature.t Sequence.t ]
       )
       Result.t =
 fun ({ config = { constraint_constants; _ }; _ } as t) committed
     ~application_status ~fee_payer_balance ~fee_payer_nonce ->
  let committed' =
    Transaction_hash.User_command_with_valid_signature.command committed
  in
  let fee_payer = User_command.fee_payer committed' in
  match Map.find t.all_by_sender fee_payer with
  | None ->
      Ok (t, Sequence.empty)
  | Some (cmds, currency_reserved) ->
      let first_cmd, rest_cmds = Option.value_exn (F_sequence.uncons cmds) in
      let first_cmd' =
        Transaction_hash.User_command_with_valid_signature.command first_cmd
      in
      let actual_target_nonce =
        actual_target_nonce committed' ~application_status
      in
      if
        Account_nonce.(
          User_command.applicable_at_nonce committed'
          <> User_command.applicable_at_nonce first_cmd')
      then
        Error
          (`Queued_txns_by_sender
            ( "Tried to handle a committed transaction in the pool but its \
               nonce doesn't match the head of the queue for that sender"
            , F_sequence.to_seq cmds ) )
      else if
        Account_nonce.(
          actual_target_nonce <> User_command.expected_target_nonce first_cmd')
      then
        (*The committed transaction invalidates the rest of sequence*)
        let dropped_cmds = F_sequence.to_seq cmds in
        let t = remove_applicable_exn t first_cmd in
        let t =
          Sequence.fold dropped_cmds ~init:t
            ~f:remove_all_by_fee_and_hash_and_expiration_exn
        in
        let t =
          { t with all_by_sender = Map.remove t.all_by_sender fee_payer }
        in
        Ok (t, dropped_cmds)
      else
        let first_cmd_consumed =
          (* safe since we checked this when we added it to the pool originally *)
          Option.value_exn (currency_consumed ~constraint_constants first_cmd)
        in
        let currency_reserved' =
          (* safe since the sum reserved must be >= reserved by any individual
             command *)
          Option.value_exn
            Currency.Amount.(currency_reserved - first_cmd_consumed)
        in
        let t1 =
          t
          |> Fn.flip remove_applicable_exn first_cmd
          |> Fn.flip remove_all_by_fee_and_hash_and_expiration_exn first_cmd
        in
        let new_queued_cmds, currency_reserved'', dropped_cmds =
          (*removed the first cmd, check if there are anymore committed transactions from the fee payer*)
          if Mina_base.Account.Nonce.(equal actual_target_nonce fee_payer_nonce)
          then
            (* remove user_commands that consume more currency than what the latest fee_payer_balance is*)
            drop_until_sufficient_balance ~constraint_constants
              (rest_cmds, currency_reserved')
              fee_payer_balance
          else
            (* Don't check if the balance is sufficient, there are other committed user_commands in the pool from the current fee payer that has been accounted for in the fee_payer_balance*)
            (rest_cmds, currency_reserved', Sequence.empty)
        in
        let t2 =
          Sequence.fold dropped_cmds ~init:t1
            ~f:remove_all_by_fee_and_hash_and_expiration_exn
        in
        let set_all_by_sender account_id commands currency_reserved t =
          match F_sequence.uncons commands with
          | None ->
              { t with all_by_sender = Map.remove t.all_by_sender account_id }
          | Some (head_cmd, _) ->
              { t with
                all_by_sender =
                  Map.set t.all_by_sender ~key:account_id
                    ~data:(commands, currency_reserved)
              ; applicable_by_fee =
                  Map_set.insert
                    (module Transaction_hash.User_command_with_valid_signature)
                    t.applicable_by_fee
                    ( head_cmd
                    |> Transaction_hash.User_command_with_valid_signature
                       .command |> User_command.fee_per_wu )
                    head_cmd
              }
        in
        let t3 =
          set_all_by_sender fee_payer new_queued_cmds currency_reserved'' t2
        in
        Ok
          ( t3
          , Sequence.append
              ( if
                Transaction_hash.User_command_with_valid_signature.equal
                  committed first_cmd
              then Sequence.empty
              else Sequence.singleton first_cmd )
              dropped_cmds )

let remove_lowest_fee :
    t -> Transaction_hash.User_command_with_valid_signature.t Sequence.t * t =
 fun t ->
  match Map.min_elt t.all_by_fee with
  | None ->
      (Sequence.empty, t)
  | Some (_min_fee, min_fee_set) ->
      remove_with_dependents_exn' t @@ Set.min_elt_exn min_fee_set

let get_highest_fee :
    t -> Transaction_hash.User_command_with_valid_signature.t option =
 fun t ->
  Option.map
    ~f:
      (Fn.compose
         Transaction_hash.User_command_with_valid_signature.Set.min_elt_exn
         Tuple2.get2 )
  @@ Currency.Fee_rate.Map.max_elt t.applicable_by_fee

(* Add a command that came in from gossip, or return an error. We need to check
   a whole bunch of conditions here and return the appropriate errors.
   Conditions:
   1. Command nonce must be >= account nonce.
   1a. If the sender's queue is empty, command nonce must equal account nonce.
   1b. If the sender's queue is non-empty, command nonce must be <= the nonce of
       the last queued command + 1
   2. The sum of the currency consumed by all queued commands for the sender
      must be <= the sender's balance.
   3. If a command is replaced, the new command must have a fee greater than the
      replaced command by at least replace fee * (number of commands after the
      the replaced command + 1)
   4. No integer overflows are allowed.
   5. protocol state predicate must be satisfiable before txs would expire
      from the pool based on age
   5a. timestamp predicate upper bound must be above current time.
   5b. timestamp predicate lower bound must be below current time plus expiration time,
       or the transaction will not become valid while in the pool
   These conditions are referenced in the comments below.
*)

module Add_from_gossip_exn (M : Writer_result.S) = struct
  let check_timestamp_predicate (expiry_ns : Time_ns.Span.t)
      (user_command : User_command.t) : bool =
    let expiry = Block_time.Span.of_time_ns_span expiry_ns in
    let current_time = Block_time.of_time_ns @@ Time_ns.now () in
    let expiry_time = Block_time.sub current_time expiry in
    match user_command with
    | User_command.Signed_command _ ->
        true
    | User_command.Parties ps ->
        ps.other_parties
        |> Parties.Call_forest.exists ~f:(fun party ->
               let predicate = Party.protocol_state_precondition party in
               match predicate.timestamp with
               | Check { lower; upper } ->
                   (*Timestamp bounds are compared against slot start time of
                     the most recent block and that could be any number of slots
                     old. So give the transaction more time to be included*)
                   Block_time.(upper <= expiry_time)
                   || Block_time.(lower >= add current_time expiry)
               | _ ->
                   false )
        |> not

  let rec add_from_gossip_exn :
         config:Config.t
      -> verify:(User_command.Verifiable.t -> (User_command.Valid.t, _, _) M.t)
      -> [ `Unchecked of
           Transaction_hash.User_command.t * User_command.Verifiable.t
         | `Checked of Transaction_hash.User_command_with_valid_signature.t ]
      -> Account_nonce.t
      -> Currency.Amount.t
      -> Sender_local_state.t ref
      -> ( Transaction_hash.User_command_with_valid_signature.t
           * Transaction_hash.User_command_with_valid_signature.t Sequence.t
         , Update.single
         , Command_error.t )
         M.t =
   fun ~config:({ constraint_constants; expiry_ns; _ } as config) ~verify cmd0
       current_nonce balance by_sender ->
    let open Command_error in
    let unchecked_cmd =
      match cmd0 with
      | `Unchecked (x, _) ->
          x
      | `Checked x ->
          Transaction_hash.User_command.of_checked x
    in
    let open M.Let_syntax in
    let verified () =
      match cmd0 with
      | `Checked x ->
          return x
      | `Unchecked (_, unchecked) ->
          let%map x = verify unchecked in
          Transaction_hash.(
            User_command_with_valid_signature.make x
              (User_command.hash unchecked_cmd))
    in
    let unchecked = Transaction_hash.User_command.data unchecked_cmd in
    let fee = User_command.fee unchecked in
    let fee_per_wu = User_command.fee_per_wu unchecked in
    let cmd_applicable_at_nonce = User_command.applicable_at_nonce unchecked in
    (* Result errors indicate problems with the command, while assert failures
       indicate bugs in Mina. *)
    let%bind consumed =
      M.of_result
        Result.Let_syntax.(
          (* C5 *)
          let%bind () =
            if check_timestamp_predicate expiry_ns unchecked then Ok ()
            else
              Error
                (Expired
                   ( `Timestamp_predicate (Time_ns.Span.to_string_hum expiry_ns)
                   , `Global_slot_since_genesis
                       (global_slot_since_genesis config) ) )
          in
          let%bind () = check_expiry config unchecked in
          let%bind consumed =
            currency_consumed' ~constraint_constants unchecked
          in
          let%map () =
            (* TODO: Proper exchange rate mechanism. *)
            let fee_token = User_command.fee_token unchecked in
            if Token_id.(equal default) fee_token then return ()
            else Error (Unwanted_fee_token fee_token)
          in
          consumed)
    in
    (* C4 *)
    match !by_sender.data with
    | None ->
        let%bind () =
          M.of_result
            Result.Let_syntax.(
              (* nothing queued for this sender *)
              let%bind () =
                Result.ok_if_true
                  (Account_nonce.equal current_nonce cmd_applicable_at_nonce)
                  ~error:
                    (Invalid_nonce
                       (`Expected current_nonce, cmd_applicable_at_nonce) )
                (* C1/1a *)
              in
              let%map () =
                Result.ok_if_true
                  Currency.Amount.(consumed <= balance)
                  ~error:(Insufficient_funds (`Balance balance, consumed))
                (* C2 *)
              in
              ())
        in
        let%bind cmd = verified () in
        let%map () =
          M.write
            (Update.Add
               { command = cmd; fee_per_wu; add_to_applicable_by_fee = true } )
        in
        by_sender :=
          { !by_sender with data = Some (F_sequence.singleton cmd, consumed) } ;
        (cmd, Sequence.empty)
    | Some (queued_cmds, reserved_currency) ->
        assert (not @@ F_sequence.is_empty queued_cmds) ;
        (* C1/C1b *)
        let queue_applicable_at_nonce =
          F_sequence.head_exn queued_cmds
          |> Transaction_hash.User_command_with_valid_signature.command
          |> User_command.applicable_at_nonce
        in
        let queue_target_nonce =
          F_sequence.last_exn queued_cmds
          |> Transaction_hash.User_command_with_valid_signature.command
          |> User_command.expected_target_nonce
        in
        if Account_nonce.equal queue_target_nonce cmd_applicable_at_nonce then (
          (* this command goes on the end *)
          let%bind reserved_currency' =
            M.of_result
              Result.Let_syntax.(
                let%bind reserved_currency' =
                  Currency.Amount.(consumed + reserved_currency)
                  |> Result.of_option ~error:Overflow
                  (* C4 *)
                in
                let%map () =
                  Result.ok_if_true
                    Currency.Amount.(balance >= reserved_currency')
                    ~error:
                      (Insufficient_funds (`Balance balance, reserved_currency'))
                  (* C2 *)
                in
                reserved_currency')
          in
          let%bind cmd = verified () in
          let new_state =
            (F_sequence.snoc queued_cmds cmd, reserved_currency')
          in
          let%map () =
            M.write
              (Update.Add
                 { command = cmd; fee_per_wu; add_to_applicable_by_fee = false }
              )
          in
          by_sender := { !by_sender with data = Some new_state } ;
          (cmd, Sequence.empty) )
        else if Account_nonce.equal queue_applicable_at_nonce current_nonce then (
          (* we're replacing a command *)
          let%bind () =
            Result.ok_if_true
              (Account_nonce.between ~low:queue_applicable_at_nonce
                 ~high:queue_target_nonce cmd_applicable_at_nonce )
              ~error:
                (Invalid_nonce
                   ( `Between (queue_applicable_at_nonce, queue_target_nonce)
                   , cmd_applicable_at_nonce ) )
            |> M.of_result
            (* C1/C1b *)
          in
          let replacement_index =
            F_sequence.findi queued_cmds ~f:(fun cmd' ->
                let cmd_applicable_at_nonce' =
                  Transaction_hash.User_command_with_valid_signature.command
                    cmd'
                  |> User_command.applicable_at_nonce
                in
                Account_nonce.compare cmd_applicable_at_nonce
                  cmd_applicable_at_nonce'
                <= 0 )
            |> Option.value_exn
          in
          let _keep_queue, drop_queue =
            F_sequence.split_at queued_cmds replacement_index
          in
          let to_drop =
            F_sequence.head_exn drop_queue
            |> Transaction_hash.User_command_with_valid_signature.command
          in
          assert (
            Account_nonce.compare cmd_applicable_at_nonce
              (User_command.applicable_at_nonce to_drop)
            <= 0 ) ;
          (* We check the fee increase twice because we need to be sure the
             subtraction is safe. *)
          let%bind () =
            let replace_fee = User_command.fee to_drop in
            Result.ok_if_true
              Currency.Fee.(fee >= replace_fee)
              ~error:(Insufficient_replace_fee (`Replace_fee replace_fee, fee))
            |> M.of_result
            (* C3 *)
          in
          let%bind dropped =
            remove_with_dependents_exn ~constraint_constants
              (F_sequence.head_exn drop_queue)
              by_sender
            |> M.lift
          in
          (* check remove_exn dropped the right things *)
          [%test_eq:
            Transaction_hash.User_command_with_valid_signature.t Sequence.t]
            dropped
            (F_sequence.to_seq drop_queue) ;
          let%bind cmd = verified () in
          (* Add the new transaction *)
          let%bind cmd, _ =
            let%map v, dropped' =
              add_from_gossip_exn ~config ~verify (`Checked cmd) current_nonce
                balance by_sender
            in
            (* We've already removed them, so this should always be empty. *)
            assert (Sequence.is_empty dropped') ;
            (v, dropped)
          in
          let drop_head, drop_tail = Option.value_exn (Sequence.next dropped) in
          let increment =
            Option.value_exn Currency.Fee.(fee - User_command.fee to_drop)
          in
          (* Re-add all of the transactions we dropped until there are none left,
             or until the fees from dropped transactions exceed the fee increase
             over the first transaction.
          *)
          let%bind increment, dropped' =
            let rec go increment dropped dropped' current_nonce : _ M.t =
              match (Sequence.next dropped, dropped') with
              | None, Some dropped' ->
                  return (increment, dropped')
              | None, None ->
                  return (increment, Sequence.empty)
              | Some (cmd, dropped), Some _ -> (
                  let cmd_unchecked =
                    Transaction_hash.User_command_with_valid_signature.command
                      cmd
                  in
                  let replace_fee = User_command.fee cmd_unchecked in
                  match Currency.Fee.(increment - replace_fee) with
                  | Some increment ->
                      go increment dropped dropped' current_nonce
                  | None ->
                      Error
                        (Insufficient_replace_fee
                           (`Replace_fee replace_fee, increment) )
                      |> M.of_result )
              | Some (cmd, dropped'), None ->
                  let current_nonce = Account_nonce.succ current_nonce in
                  let by_sender_pre = !by_sender in
                  M.catch
                    (add_from_gossip_exn ~config ~verify (`Checked cmd)
                       current_nonce balance by_sender )
                    ~f:(function
                      | Ok ((_v, dropped_), ups) ->
                          assert (Sequence.is_empty dropped_) ;
                          let%bind () = M.write_all ups in
                          go increment dropped' None current_nonce
                      | Error _err ->
                          by_sender := by_sender_pre ;
                          (* Re-evaluate with the same [dropped] to calculate the new
                             fee increment.
                          *)
                          go increment dropped (Some dropped') current_nonce )
            in
            go increment drop_tail None current_nonce
          in
          let%map () =
            Result.ok_if_true
              Currency.Fee.(increment >= replace_fee)
              ~error:
                (Insufficient_replace_fee (`Replace_fee replace_fee, increment))
            |> M.of_result
            (* C3 *)
          in
          (cmd, Sequence.(append (return drop_head) dropped')) )
        else
          (*Invalid nonce or duplicate transaction got in- either way error*)
          M.of_result
            (Error
               (Invalid_nonce
                  (`Expected queue_target_nonce, cmd_applicable_at_nonce) ) )
end

module Add_from_gossip_exn0 = Add_from_gossip_exn (Writer_result)

let add_from_gossip_exn t ~verify cmd0 nonce balance :
    ( Transaction_hash.User_command_with_valid_signature.t
      * t
      * Transaction_hash.User_command_with_valid_signature.t Sequence.t
    , Command_error.t )
    Result.t =
  let x =
    Add_from_gossip_exn0.add_from_gossip_exn ~config:t.config
      ~verify:(fun c ->
        Result.of_option (verify c) ~error:Command_error.Verification_failed
        |> Writer_result.of_result )
      cmd0 nonce balance
  in
  Result.map
    ~f:(fun ((c, cs), t) -> (c, t, cs))
    ( match cmd0 with
    | `Checked cmd ->
        run' t cmd x
    | `Unchecked (cmd, _) ->
        run t
          ~sender:
            (User_command.fee_payer (Transaction_hash.User_command.command cmd))
          x )

module Add_from_gossip_exn_async = Add_from_gossip_exn (Writer_result.Deferred)

let add_from_gossip_exn_async ~config
    ~(sender_local_state : Sender_local_state.t) ~verify cmd0 nonce balance =
  let open Async in
  let r = ref sender_local_state in
  let x =
    Add_from_gossip_exn_async.add_from_gossip_exn ~config
      ~verify:(fun c ->
        Writer_result.Deferred.Deferred
          (Deferred.map (verify c) ~f:(fun r ->
               Result.of_option r ~error:Command_error.Verification_failed
               |> Writer_result.of_result ) ) )
      cmd0 nonce balance r
  in
  Deferred.Result.map (Writer_result.Deferred.run x) ~f:(fun ((c, cs), us) ->
      ((c, Sequence.to_list cs), !r, us) )

(** Add back the commands that were removed due to a reorg*)
let add_from_backtrack :
       t
    -> Transaction_hash.User_command_with_valid_signature.t
    -> (t, Command_error.t) Result.t =
 fun ({ config = { constraint_constants; _ }; _ } as t) cmd ->
  let open Result.Let_syntax in
  let unchecked =
    Transaction_hash.User_command_with_valid_signature.command cmd
  in
  let%map () = check_expiry t.config unchecked in
  let fee_payer = User_command.fee_payer unchecked in
  let fee_per_wu = User_command.fee_per_wu unchecked in
  let entry_time = Time_ns.now () in
  let cmd_hash = Transaction_hash.User_command_with_valid_signature.hash cmd in
  let consumed =
    Option.value_exn (currency_consumed ~constraint_constants cmd)
  in
  match Map.find t.all_by_sender fee_payer with
  | None ->
      { all_by_sender =
          (* If the command comes from backtracking, then we know it doesn't
             cause overflow, so it's OK to throw here.
          *)
          Map.add_exn t.all_by_sender ~key:fee_payer
            ~data:(F_sequence.singleton cmd, consumed)
      ; all_by_fee =
          Map_set.insert
            (module Transaction_hash.User_command_with_valid_signature)
            t.all_by_fee fee_per_wu cmd
      ; all_by_hash = Map.set t.all_by_hash ~key:cmd_hash ~data:cmd
      ; applicable_by_fee =
          Map_set.insert
            (module Transaction_hash.User_command_with_valid_signature)
            t.applicable_by_fee fee_per_wu cmd
      ; transactions_with_expiration =
          add_to_expiration t.transactions_with_expiration cmd
      ; entry_times = Map.add_exn t.entry_times ~key:cmd_hash ~data:entry_time
      ; all_by_entry_time =
          Map.add_exn t.all_by_entry_time ~key:entry_time ~data:cmd_hash
      ; size = t.size + 1
      ; config = t.config
      }
  | Some (queue, currency_reserved) ->
      let first_queued = F_sequence.head_exn queue in
      if
        not
          (Account_nonce.equal
             (unchecked |> User_command.expected_target_nonce)
             ( first_queued
             |> Transaction_hash.User_command_with_valid_signature.command
             |> User_command.applicable_at_nonce ) )
      then
        failwith
        @@ sprintf
             !"indexed pool nonces inconsistent when adding from backtrack. \
               Trying to add \
               %{sexp:Transaction_hash.User_command_with_valid_signature.t} to \
               %{sexp: t}"
             cmd t ;
      let t' = remove_applicable_exn t first_queued in
      { applicable_by_fee =
          Map_set.insert
            (module Transaction_hash.User_command_with_valid_signature)
            t'.applicable_by_fee fee_per_wu cmd
      ; all_by_fee =
          Map_set.insert
            (module Transaction_hash.User_command_with_valid_signature)
            t'.all_by_fee fee_per_wu cmd
      ; all_by_hash =
          Map.set t.all_by_hash
            ~key:(Transaction_hash.User_command_with_valid_signature.hash cmd)
            ~data:cmd
      ; all_by_sender =
          Map.set t'.all_by_sender ~key:fee_payer
            ~data:
              ( F_sequence.cons cmd queue
              , Option.value_exn Currency.Amount.(currency_reserved + consumed)
              )
      ; transactions_with_expiration =
          add_to_expiration t.transactions_with_expiration cmd
      ; entry_times = Map.add_exn t.entry_times ~key:cmd_hash ~data:entry_time
      ; all_by_entry_time =
          Map.add_exn t.all_by_entry_time ~key:entry_time ~data:cmd_hash
      ; size = t.size + 1
      ; config = t.config
      }

let global_slot_since_genesis t = global_slot_since_genesis t.config

(* Only show stdout for failed inline tests. *)
open Inline_test_quiet_logs

let%test_module _ =
  ( module struct
    open For_tests

    let test_keys = Array.init 10 ~f:(fun _ -> Signature_lib.Keypair.create ())

    let gen_cmd ?sign_type ?nonce () =
      User_command.Valid.Gen.payment_with_random_participants ~keys:test_keys
        ~max_amount:1000 ~fee_range:10 ?sign_type ?nonce ()
      |> Quickcheck.Generator.map
           ~f:Transaction_hash.User_command_with_valid_signature.create

    let precomputed_values = Lazy.force Precomputed_values.for_unit_tests

    let constraint_constants = precomputed_values.constraint_constants

    let consensus_constants = precomputed_values.consensus_constants

    let logger = Logger.null ()

    let time_controller = Block_time.Controller.basic ~logger

    let expiry_ns =
      Time_ns.Span.of_hr
        (Float.of_int precomputed_values.genesis_constants.transaction_expiry_hr)

    let empty =
      empty ~constraint_constants ~consensus_constants ~time_controller
        ~expiry_ns

    let%test_unit "empty invariants" = assert_invariants empty

    let don't_verify _ = None

    let%test_unit "singleton properties" =
      Quickcheck.test (gen_cmd ()) ~f:(fun cmd ->
          let pool = empty in
          let add_res =
            add_from_gossip_exn pool (`Checked cmd) Account_nonce.zero
              ~verify:don't_verify
              (Currency.Amount.of_int 500)
          in
          if
            Option.value_exn (currency_consumed ~constraint_constants cmd)
            |> Currency.Amount.to_int > 500
          then
            match add_res with
            | Error (Insufficient_funds _) ->
                ()
            | _ ->
                failwith "should've returned insufficient_funds"
          else
            match add_res with
            | Ok (_, pool', dropped) ->
                assert_invariants pool' ;
                assert (Sequence.is_empty dropped) ;
                [%test_eq: int] (size pool') 1 ;
                [%test_eq:
                  Transaction_hash.User_command_with_valid_signature.t option]
                  (get_highest_fee pool') (Some cmd) ;
                let dropped', pool'' = remove_lowest_fee pool' in
                [%test_eq:
                  Transaction_hash.User_command_with_valid_signature.t
                  Sequence.t] dropped' (Sequence.singleton cmd) ;
                [%test_eq: t] ~equal pool pool''
            | _ ->
                failwith "should've succeeded" )

    let%test_unit "age-based expiry" =
      Quickcheck.test ~trials:1
        (Mina_generators.User_command_generators.parties_with_ledger ())
        ~f:(fun (cmd, _, _, _) ->
          let cmd =
            Transaction_hash.User_command_with_valid_signature.create cmd
          in
          let pool =
            { empty with
              config = { empty.config with expiry_ns = Time_ns.Span.of_sec 5.0 }
            }
          in
          add_from_gossip_exn pool (`Checked cmd) Account_nonce.zero
            ~verify:don't_verify
            (Currency.Amount.of_int 3000_000_000_000_000)
          |> function
          | Ok (_, pool', dropped) ->
              assert (Sequence.is_empty dropped) ;
              Unix.sleep 15 ;
              let dropped, _ = remove_expired pool' in
              assert (not @@ Sequence.is_empty dropped)
          | Error e ->
              failwithf !"Error: %{sexp: Command_error.t}" e () )

    let%test_unit "sequential adds (all valid)" =
      let gen :
          ( Mina_ledger.Ledger.init_state
          * Transaction_hash.User_command_with_valid_signature.t list )
          Quickcheck.Generator.t =
        let open Quickcheck.Generator.Let_syntax in
        let%bind ledger_init = Mina_ledger.Ledger.gen_initial_ledger_state in
        let%map cmds = User_command.Valid.Gen.sequence ledger_init in
        ( ledger_init
        , List.map ~f:Transaction_hash.User_command_with_valid_signature.create
            cmds )
      in
      let shrinker :
          ( Mina_ledger.Ledger.init_state
          * Transaction_hash.User_command_with_valid_signature.t list )
          Quickcheck.Shrinker.t =
        Quickcheck.Shrinker.create (fun (init_state, cmds) ->
            Sequence.singleton
              (init_state, List.take cmds (List.length cmds - 1)) )
      in
      Quickcheck.test gen ~trials:1000
        ~sexp_of:
          [%sexp_of:
            Mina_ledger.Ledger.init_state
            * Transaction_hash.User_command_with_valid_signature.t list]
        ~shrinker ~shrink_attempts:`Exhaustive ~seed:(`Deterministic "d")
        ~sizes:(Sequence.repeat 10) ~f:(fun (ledger_init, cmds) ->
          let account_init_states_seq = Array.to_sequence ledger_init in
          let balances = Hashtbl.create (module Public_key.Compressed) in
          let nonces = Hashtbl.create (module Public_key.Compressed) in
          Sequence.iter account_init_states_seq
            ~f:(fun (kp, balance, nonce, _) ->
              let compressed = Public_key.compress kp.public_key in
              Hashtbl.add_exn balances ~key:compressed ~data:balance ;
              Hashtbl.add_exn nonces ~key:compressed ~data:nonce ) ;
          let pool = ref empty in
          let rec go cmds_acc =
            match cmds_acc with
            | [] ->
                ()
            | cmd :: rest -> (
                let unchecked =
                  Transaction_hash.User_command_with_valid_signature.command cmd
                in
                let account_id = User_command.fee_payer unchecked in
                let pk = Account_id.public_key account_id in
                let add_res =
                  add_from_gossip_exn !pool (`Checked cmd) ~verify:don't_verify
                    (Hashtbl.find_exn nonces pk)
                    (Hashtbl.find_exn balances pk)
                in
                match add_res with
                | Ok (_, pool', dropped) ->
                    [%test_eq:
                      Transaction_hash.User_command_with_valid_signature.t
                      Sequence.t] dropped Sequence.empty ;
                    assert_invariants pool' ;
                    pool := pool' ;
                    go rest
                | Error (Invalid_nonce (`Expected want, got)) ->
                    failwithf
                      !"Bad nonce. Expected: %{sexp: Account.Nonce.t}. Got: \
                        %{sexp: Account.Nonce.t}"
                      want got ()
                | Error (Invalid_nonce (`Between (low, high), got)) ->
                    failwithf
                      !"Bad nonce. Expected between %{sexp: Account.Nonce.t} \
                        and %{sexp:Account.Nonce.t}. Got: %{sexp: \
                        Account.Nonce.t}"
                      low high got ()
                | Error (Insufficient_funds (`Balance bal, amt)) ->
                    failwithf
                      !"Insufficient funds. Balance: %{sexp: \
                        Currency.Amount.t}. Amount: %{sexp: Currency.Amount.t}"
                      bal amt ()
                | Error (Insufficient_replace_fee (`Replace_fee rfee, fee)) ->
                    failwithf
                      !"Insufficient fee for replacement. Needed at least \
                        %{sexp: Currency.Fee.t} but got \
                        %{sexp:Currency.Fee.t}."
                      rfee fee ()
                | Error Overflow ->
                    failwith "Overflow."
                | Error Bad_token ->
                    failwith "Token is incompatible with the command."
                | Error Verification_failed ->
                    failwith
                      "Transaction had invalid proof/signature or was malformed"
                | Error (Unwanted_fee_token fee_token) ->
                    failwithf
                      !"Bad fee token. The fees are paid in token %{sexp: \
                        Token_id.t}, which we are not accepting fees in."
                      fee_token ()
                | Error
                    (Expired
                      ( `Valid_until valid_until
                      , `Global_slot_since_genesis global_slot_since_genesis )
                      ) ->
                    failwithf
                      !"Expired user command. Current global slot is \
                        %{sexp:Mina_numbers.Global_slot.t} but user command is \
                        only valid until %{sexp:Mina_numbers.Global_slot.t}"
                      global_slot_since_genesis valid_until ()
                | Error
                    (Expired
                      ( `Timestamp_predicate expiry_ns
                      , `Global_slot_since_genesis global_slot_since_genesis )
                      ) ->
                    failwithf
                      !"Expired zkapp. Current global slot is \
                        %{sexp:Mina_numbers.Global_slot.t}. Transaction \
                        expired or will expire in the pool based on the \
                        current expiry duration of %s"
                      global_slot_since_genesis expiry_ns () )
          in
          go cmds )

    let%test_unit "replacement" =
      let modify_payment (c : User_command.t) ~sender ~common:fc ~body:fb =
        let modified_payload : Signed_command.Payload.t =
          match c with
          | Signed_command
              { payload = { body = Payment payment_payload; common }; _ } ->
              { common = fc common
              ; body = Signed_command.Payload.Body.Payment (fb payment_payload)
              }
          | _ ->
              failwith "generated user command that wasn't a payment"
        in
        Signed_command
          (Signed_command.For_tests.fake_sign sender modified_payload)
        |> Transaction_hash.User_command_with_valid_signature.create
      in
      let gen :
          ( Account_nonce.t
          * Currency.Amount.t
          * Transaction_hash.User_command_with_valid_signature.t list
          * Transaction_hash.User_command_with_valid_signature.t )
          Quickcheck.Generator.t =
        let open Quickcheck.Generator.Let_syntax in
        let%bind sender_index = Int.gen_incl 0 9 in
        let sender = test_keys.(sender_index) in
        let%bind init_nonce =
          Quickcheck.Generator.map ~f:Account_nonce.of_int
          @@ Int.gen_incl 0 1000
        in
        let init_balance = Currency.Amount.of_int 100_000_000_000_000 in
        let%bind size = Quickcheck.Generator.size in
        let%bind amounts =
          Quickcheck.Generator.map ~f:Array.of_list
          @@ Quickcheck_lib.gen_division_currency init_balance (size + 1)
        in
        let rec go current_nonce current_balance n =
          if n > 0 then
            let%bind cmd =
              let key_gen =
                Quickcheck.Generator.tuple2 (return sender)
                  (Quickcheck_lib.of_array test_keys)
              in
              Mina_generators.User_command_generators.payment ~sign_type:`Fake
                ~key_gen ~nonce:current_nonce ~max_amount:1 ~fee_range:0 ()
            in
            let cmd_currency = amounts.(n - 1) in
            let%bind fee =
              Currency.Amount.(gen_incl zero (min (of_int 10) cmd_currency))
            in
            let amount =
              Option.value_exn Currency.Amount.(cmd_currency - fee)
            in
            let cmd' =
              modify_payment cmd ~sender
                ~common:(fun c -> { c with fee = Currency.Amount.to_fee fee })
                ~body:(fun b -> { b with amount })
            in
            let consumed =
              Option.value_exn (currency_consumed ~constraint_constants cmd')
            in
            let%map rest =
              go
                (Account_nonce.succ current_nonce)
                (Option.value_exn Currency.Amount.(current_balance - consumed))
                (n - 1)
            in
            cmd' :: rest
          else return []
        in
        let%bind setup_cmds = go init_nonce init_balance (size + 1) in
        let init_nonce_int = Account.Nonce.to_int init_nonce in
        let%bind replaced_nonce =
          Int.gen_incl init_nonce_int
            (init_nonce_int + List.length setup_cmds - 1)
        in
        let%map replace_cmd_skeleton =
          let key_gen =
            Quickcheck.Generator.tuple2 (return sender)
              (Quickcheck_lib.of_array test_keys)
          in
          Mina_generators.User_command_generators.payment ~sign_type:`Fake
            ~key_gen
            ~nonce:(Account_nonce.of_int replaced_nonce)
            ~max_amount:(Currency.Amount.to_int init_balance)
            ~fee_range:0 ()
        in
        let replace_cmd =
          modify_payment replace_cmd_skeleton ~sender ~body:Fn.id
            ~common:(fun c ->
              { c with
                fee =
                  Currency.Fee.of_int ((10 + (5 * (size + 1))) * 1_000_000_000)
              } )
        in
        (init_nonce, init_balance, setup_cmds, replace_cmd)
      in
      Quickcheck.test ~trials:20 gen
        ~sexp_of:
          [%sexp_of:
            Account_nonce.t
            * Currency.Amount.t
            * Transaction_hash.User_command_with_valid_signature.t list
            * Transaction_hash.User_command_with_valid_signature.t]
        ~f:(fun (init_nonce, init_balance, setup_cmds, replace_cmd) ->
          let t =
            List.fold_left setup_cmds ~init:empty ~f:(fun t cmd ->
                match
                  add_from_gossip_exn t (`Checked cmd) init_nonce init_balance
                    ~verify:don't_verify
                with
                | Ok (_, t', removed) ->
                    [%test_eq:
                      Transaction_hash.User_command_with_valid_signature.t
                      Sequence.t] removed Sequence.empty ;
                    t'
                | _ ->
                    failwith
                    @@ sprintf
                         !"adding command %{sexp: \
                           Transaction_hash.User_command_with_valid_signature.t} \
                           failed"
                         cmd )
          in
          let replaced_idx, _ =
            let replace_nonce =
              replace_cmd
              |> Transaction_hash.User_command_with_valid_signature.command
              |> User_command.applicable_at_nonce
            in
            List.findi setup_cmds ~f:(fun _i cmd ->
                let cmd_nonce =
                  cmd
                  |> Transaction_hash.User_command_with_valid_signature.command
                  |> User_command.applicable_at_nonce
                in
                Account_nonce.compare replace_nonce cmd_nonce <= 0 )
            |> Option.value_exn
          in
          let deprecated_replaced_idx =
            Account_nonce.to_int
              ( replace_cmd
              |> Transaction_hash.User_command_with_valid_signature.command
              |> User_command.applicable_at_nonce )
            - Account_nonce.to_int
                ( List.hd_exn setup_cmds
                |> Transaction_hash.User_command_with_valid_signature.command
                |> User_command.applicable_at_nonce )
          in
          Printf.printf
            !"replacement indices: new=%d, old=%d\n%!"
            replaced_idx deprecated_replaced_idx ;
          let currency_consumed_pre_replace =
            List.fold_left
              (List.take setup_cmds (replaced_idx + 1))
              ~init:Currency.Amount.zero
              ~f:(fun consumed_so_far cmd ->
                Option.value_exn
                  Option.(
                    currency_consumed ~constraint_constants cmd
                    >>= fun consumed ->
                    Currency.Amount.(consumed + consumed_so_far)) )
          in
          assert (
            Currency.Amount.(currency_consumed_pre_replace <= init_balance) ) ;
          let currency_consumed_post_replace =
            Option.value_exn
              (let open Option.Let_syntax in
              let%bind replaced_currency_consumed =
                currency_consumed ~constraint_constants
                @@ List.nth_exn setup_cmds replaced_idx
              in
              let%bind replacer_currency_consumed =
                currency_consumed ~constraint_constants replace_cmd
              in
              let%bind a =
                Currency.Amount.(
                  currency_consumed_pre_replace - replaced_currency_consumed)
              in
              Currency.Amount.(a + replacer_currency_consumed))
          in
          let add_res =
            add_from_gossip_exn t (`Checked replace_cmd) init_nonce init_balance
              ~verify:don't_verify
          in
          if Currency.Amount.(currency_consumed_post_replace <= init_balance)
          then
            match add_res with
            | Ok (_, t', dropped) ->
                assert (not (Sequence.is_empty dropped)) ;
                assert_invariants t'
            | Error _ ->
                failwith "adding command failed"
          else
            match add_res with
            | Error (Insufficient_funds _) ->
                ()
            | _ ->
                failwith "should've returned insufficient_funds" )

    let%test_unit "remove_lowest_fee" =
      let cmds =
        gen_cmd () |> Quickcheck.random_sequence |> Fn.flip Sequence.take 4
        |> Sequence.to_list
      in
      let compare cmd0 cmd1 : int =
        let open Transaction_hash.User_command_with_valid_signature in
        Currency.Fee_rate.compare
          (User_command.fee_per_wu @@ command cmd0)
          (User_command.fee_per_wu @@ command cmd1)
      in
      let cmds_sorted_by_fee_per_wu = List.sort ~compare cmds in
      let cmd_lowest_fee, commands_to_keep =
        ( List.hd_exn cmds_sorted_by_fee_per_wu
        , List.tl_exn cmds_sorted_by_fee_per_wu )
      in
      let insert_cmd pool cmd =
        add_from_gossip_exn ~verify:don't_verify pool (`Checked cmd)
          Account_nonce.zero
          (Currency.Amount.of_int (500 * 10_000_000))
        |> Result.ok |> Option.value_exn
        |> fun (_, pool, _) -> pool
      in
      let cmd_equal =
        Transaction_hash.User_command_with_valid_signature.equal
      in
      let removed, pool =
        List.fold_left cmds ~init:empty ~f:insert_cmd |> remove_lowest_fee
      in
      (* check that the lowest fee per wu command is returned *)
      assert (Sequence.(equal cmd_equal removed @@ return cmd_lowest_fee))
      |> fun () ->
      (* check that the lowest fee per wu command is removed from
         applicable_by_fee *)
      pool.applicable_by_fee |> Map.data
      |> List.concat_map ~f:Set.to_list
      |> fun applicable_by_fee_cmds ->
      assert (List.(equal cmd_equal applicable_by_fee_cmds commands_to_keep))
      |> fun () ->
      (* check that the lowest fee per wu command is removed from
         all_by_fee *)
      pool.applicable_by_fee |> Map.data
      |> List.concat_map ~f:Set.to_list
      |> fun all_by_fee_cmds ->
      assert (List.(equal cmd_equal all_by_fee_cmds commands_to_keep))

    let%test_unit "get_highest_fee" =
      let cmds =
        gen_cmd () |> Quickcheck.random_sequence |> Fn.flip Sequence.take 4
        |> Sequence.to_list
      in
      let compare cmd0 cmd1 : int =
        let open Transaction_hash.User_command_with_valid_signature in
        Currency.Fee_rate.compare
          (User_command.fee_per_wu @@ command cmd0)
          (User_command.fee_per_wu @@ command cmd1)
      in
      let max_by_fee_per_wu = List.max_elt ~compare cmds |> Option.value_exn in
      let insert_cmd pool cmd =
        add_from_gossip_exn ~verify:don't_verify pool (`Checked cmd)
          Account_nonce.zero
          (Currency.Amount.of_int (500 * 10_000_000))
        |> Result.ok |> Option.value_exn
        |> fun (_, pool, _) -> pool
      in
      let pool = List.fold_left cmds ~init:empty ~f:insert_cmd in
      let cmd_equal =
        Transaction_hash.User_command_with_valid_signature.equal
      in
      get_highest_fee pool |> Option.value_exn
      |> fun highest_fee -> assert (cmd_equal highest_fee max_by_fee_per_wu)

    let%test_unit "support for parties commands" =
      let open Mina_transaction_logic.For_tests in
      let fee = Mina_compile_config.minimum_user_command_fee in
      let amount = Currency.(Amount.of_int @@ Fee.to_int fee) in
      let balance = Option.value_exn (Currency.Amount.scale amount 100) in
      let kp1 =
        Quickcheck.random_value ~seed:(`Deterministic "apple") Keypair.gen
      in
      let kp2 =
        Quickcheck.random_value ~seed:(`Deterministic "orange") Keypair.gen
      in
      let pk2 = Public_key.compress kp2.public_key in
      let add_to_pool cmd pool =
        let _, pool', dropped =
          add_from_gossip_exn pool (`Checked cmd) ~verify:don't_verify
            Account_nonce.zero balance
          |> Result.map_error
               ~f:(Fn.compose Sexp.to_string Command_error.sexp_of_t)
          |> Result.ok_or_failwith
        in
        [%test_eq:
          Transaction_hash.User_command_with_valid_signature.t Sequence.t]
          dropped Sequence.empty ;
        assert_invariants pool' ;
        pool'
      in
      let commit_to_pool cmd ~application_status ~fee_payer_balance
          ~expected_drops pool =
        let fee_payer_nonce =
          User_command.expected_target_nonce
          @@ Transaction_hash.User_command_with_valid_signature.command cmd
        in
        let pool, dropped =
          handle_committed_txn pool cmd
            ~application_status:(Some application_status) ~fee_payer_balance
            ~fee_payer_nonce
          |> Result.map_error ~f:(fun (`Queued_txns_by_sender (error, _)) ->
                 error )
          |> Result.ok_or_failwith
        in
        [%test_eq:
          Transaction_hash.User_command_with_valid_signature.t Sequence.t]
          dropped expected_drops ;
        assert_invariants pool ;
        pool
      in
      let make_cmd ~double_increment nonce =
        let (`If_this_is_used_it_should_have_a_comment_justifying_it c) =
          User_command.to_valid_unsafe
            (User_command.Parties
               (party_send ~use_full_commitment:(not double_increment)
                  ~double_sender_nonce:false ~constraint_constants
                  { fee
                  ; sender = (kp1, Account_nonce.of_int nonce)
                  ; receiver = pk2
                  ; amount
                  ; receiver_is_new = false
                  } ) )
        in
        Transaction_hash.User_command_with_valid_signature.create c
      in
      let balance_after_cmd n =
        Option.value_exn
          Currency.Amount.(sub balance (scale amount n |> Option.value_exn))
      in
      Mina_ledger.Ledger.with_ledger ~depth:4 ~f:(fun ledger ->
          Init_ledger.init
            (module Mina_ledger.Ledger.Ledger_inner)
            [| (kp1, Int64.(of_int @@ Currency.Amount.to_int balance))
             ; (kp2, 0L)
            |]
            ledger ;
          let cmd1 = make_cmd ~double_increment:false 0 in
          let cmd2 = make_cmd ~double_increment:false 1 in
          let cmd3 = make_cmd ~double_increment:false 2 in
          let cmd4 = make_cmd ~double_increment:false 3 in
          let cmd5 = make_cmd ~double_increment:false 4 in
          let cmd6 = make_cmd ~double_increment:false 5 in
          let cmd7 = make_cmd ~double_increment:false 6 in
          (* used to break the sequence *)
          (* same as cmd3. should not drop anything*)
          let cmd3' = make_cmd ~double_increment:false 2 in
          (*command with multiple fee payer increments but failed. Equivalent to one fee payer increment, drops cmd4 because it is a different command but keeps the rest*)
          let cmd4_failed = make_cmd ~double_increment:true 3 in
          (*command with multiple fee payer increments but applied. drops cmd5 because it is different and invalidates the rest of the queue*)
          let cmd5' = make_cmd ~double_increment:true 4 in
          ignore
            ( empty |> add_to_pool cmd1 |> add_to_pool cmd2 |> add_to_pool cmd3
              |> add_to_pool cmd4 |> add_to_pool cmd5 |> add_to_pool cmd6
              |> add_to_pool cmd7
              |> commit_to_pool cmd1 ~application_status:Applied
                   ~fee_payer_balance:(balance_after_cmd 1)
                   ~expected_drops:Sequence.empty
              |> commit_to_pool cmd2 ~application_status:Applied
                   ~fee_payer_balance:(balance_after_cmd 2)
                   ~expected_drops:Sequence.empty
              |> commit_to_pool cmd3' ~application_status:Applied
                   ~fee_payer_balance:(balance_after_cmd 3)
                   ~expected_drops:Sequence.empty
              |> commit_to_pool cmd4_failed
                   ~application_status:
                     (Failed
                        Transaction_status.Failure.(
                          Collection.of_single_failure
                            Update_not_permitted_balance) )
                   ~fee_payer_balance:(balance_after_cmd 4)
                   ~expected_drops:(Sequence.singleton cmd4)
              |> commit_to_pool cmd5' ~application_status:Applied
                   ~fee_payer_balance:(balance_after_cmd 5)
                   ~expected_drops:(Sequence.of_list [ cmd5; cmd6; cmd7 ])
              : t )
          (*
          |> apply_to_pool (balance_after_cmd 0) cmd1
          |> apply_to_pool (balance_after_cmd 1) cmd2
          |> apply_to_pool (balance_after_cmd 2) cmd3
          |> apply_to_pool (balance_after_cmd 3) cmd4
          *) )
  end )
