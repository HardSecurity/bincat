(*
    This file is part of BinCAT.
    Copyright 2014-2018 - Airbus

    BinCAT is free software: you can redistribute it and/or modify
    it under the terms of the GNU Affero General Public License as published by
    the Free Software Foundation, either version 3 of the License, or (at your
    option) any later version.

    BinCAT is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU Affero General Public License for more details.

    You should have received a copy of the GNU Affero General Public License
    along with BinCAT.  If not, see <http://www.gnu.org/licenses/>.
 *)

(* k-set of Unrel *)
module Make(D: Unrel.T) =
  struct
    module U = Unrel.Make(D)
    module USet = Set.Make(struct type t = U.t let compare = U.total_order end)
    type t =
      | BOT
      | Val of USet.t

    let init () = USet.singleton U.empty
                
    let bot = BOT
            
    let is_bot m = m = BOT

    let imprecise_exn r =
      raise (Exceptions.Too_many_concrete_elements (Printf.sprintf "value of register %s is too much imprecise" (Register.name r)))
      
    let value_of_register m r =
      match m with
      | BOT -> raise (Exceptions.Empty (Printf.sprintf "unrel.value_of_register:  environment is empty; can't look up register %s" (Register.name r)))
      | Val m' ->
         let v = USet.fold (fun u prev ->
                     let v' = U.value_of_register u r in
                     match prev with
                     | None -> Some v'
                     | Some v ->
                        if Z.compare v v' = 0 then prev
                        else imprecise_exn r
                   ) m' None
         in
           match v with
           | None -> imprecise_exn r
           | Some v' -> v'

         
    let string_of_register m r =
      match m with
      | BOT ->  raise (Exceptions.Empty (Printf.sprintf "string_of_register: environment is empty; can't look up register %s" (Register.name r)))
      | Val m' -> USet.fold (fun u acc -> (U.string_of_register u r)^acc) m' ""

    let forget m = USet.map U.forget m

    let is_subset m1 m2 =
      match m1, m2 with
      | BOT, _ -> true
      | _, BOT -> false
      | Val m1', Val m2' ->
         USet.for_all (fun u1 ->
             USet.exists (fun u2 -> U.is_subset u1 u2) m2') m1'

    let remove_register r m =
      match m with
      | Val m' -> Val (USet.map (U.remove_register r) m')
      | BOT -> BOT

    let forget_lval lv m check_address_validity =
       match m with
      | BOT -> BOT
      | Val m' -> Val (USet.map (fun u -> U.forget_lval lv u check_address_validity) m')
                
    let add_register r m =
      match m with
      | BOT -> Val (USet.singleton (U.add_register r (U.empty)))
      | Val m' -> Val (USet.map (U.add_register r) m')

    let to_string m =
      match m with
      | BOT    -> ["_"]
      | Val m' -> USet.fold (fun u acc -> (U.to_string u) @ acc) m' []

    let imprecise_value_of_exp e =
      raise (Exceptions.Too_many_concrete_elements (Printf.sprintf "concretisation of expression %s is too much imprecise" (Asm.string_of_exp e true)))
      
    let value_of_exp m e check_address_validity =
      match m with
      | BOT -> raise (Exceptions.Empty "unrels.value_of_exp: environment is empty")
      | Val m' -> let v = USet.fold (fun u prev ->
                     let v' = U.value_of_exp u e check_address_validity in
                     match prev with
                     | None -> Some v'
                     | Some v ->
                        if Z.compare v v' = 0 then prev
                        else imprecise_value_of_exp e
                   ) m' None
         in
           match v with
           | None -> imprecise_value_of_exp e
           | Some v' -> v'

    let set dst src m check_address_validity: (t * Taint.Set.t) =
      match m with
      | BOT    -> BOT, Taint.Set.singleton Taint.U
      | Val m' ->
         let taint = ref (Taint.Set.empty) in
         let m2 = USet.map (fun u ->
                      let u', t = U.set dst src u check_address_validity in
                      taint := Taint.Set.add t !taint;
                      u') m'
         in
         Val m2, !taint

    (* auxiliary function that will join all set elements *)
    let merge m =
      let ulist = USet.elements m in
      match ulist with
      | [] -> USet.empty
      | u::tl -> USet.singleton (List.fold_left (fun acc u -> U.join acc u) u tl)
               
    let set_lval_to_addr lv addrs m check_address_validity =
      match m with
      | BOT -> BOT, Taint.Set.singleton Taint.BOT
      | Val m' ->
         let m' =
           (* check if resulting size would not exceed the kset bound *)
           if (USet.cardinal m') + (List.length addrs) > !Config.kset_bound then
             merge m'
           else m'
         in
         let taint = ref (Taint.Set.empty) in
         let m2 =
           List.fold_left (fun acc a ->
               let m' =
                 USet.map (fun u ->
                     let u', t = U.set_lval_to_addr lv a u check_address_validity in
                     taint := Taint.Set.add t !taint;
                     u') m'
               in
               USet.union acc m'
             ) USet.empty addrs
         in
         Val m2, !taint

  
         
    let join m1 m2 =
      match m1, m2 with
      | BOT, m | m, BOT -> m
      | Val m1', Val m2' ->
         let m = USet.union m1' m2' in
         (* check if the size of m exceeds the threshold *)
         if USet.cardinal m > !Config.kset_bound then
           Val (USet.union (merge m1' ) (merge m2'))
         else
           Val m

    let meet m1 m2 =
      let bot = ref false in
      let add_one_meet m u1 u2 =
        try
          USet.add (U.meet u1 u2) m
        with Exceptions.Empty _ ->
          bot := true;
          m
      in
      match m1, m2 with
      | BOT, _ | _, BOT -> BOT
      | Val m1', Val m2' ->
         let m' =
           USet.fold (fun u1 m' ->
               let mm = USet.fold (fun u2 m -> (add_one_meet m u1 u2)) m2' USet.empty in
               USet.union mm m'
             ) m1' USet.empty
         in
         let card = USet.cardinal m' in
         if card > !Config.kset_bound then
           Val (merge m')
         else
           (* check if result is BOT *)
           if card = 0 && !bot then
             BOT
           else
             Val m'

    let widen m1 m2 =
      match m1, m2 with
      | BOT, m | m, BOT  -> m
      | Val m1', Val m2' ->
         let mm1 = merge m1' in
         let mm2 = merge m2' in
         let u' =
           match USet.elements mm1, USet.elements mm2 with
               | [], _ | _, [] -> U.empty
               | u1::_, u2::_ -> U.widen u1 u2
         in
         Val (USet.singleton u')

            
    let fold_on_taint m f =
      match m with
      | BOT -> BOT,  Taint.Set.singleton Taint.BOT
      | Val m' ->
         let m', t' =
           USet.fold (fun u (m, t) ->
               let u', t' = f u in
               USet.add u' m, Taint.Set.add t' t) m' (USet.empty, Taint.Set.empty)
         in
         Val m', t'
         
    let set_memory_from_config a r conf nb m: t * Taint.Set.t = 
      if nb > 0 then
        fold_on_taint m (U.set_memory_from_config a r conf nb)
      else
        m, Taint.Set.singleton Taint.U

   
         
    let set_register_from_config r region conf m = fold_on_taint m (U.set_register_from_config r region conf)
         
    let taint_register_mask reg taint m = fold_on_taint m (U.taint_register_mask reg taint)

    let span_taint_to_register reg taint m = fold_on_taint m (U.span_taint_to_register reg taint)

    let taint_address_mask a taints m = fold_on_taint m (U.taint_address_mask a taints)

    let span_taint_to_addr a t m = fold_on_taint m (U.span_taint_to_addr a t)

    let compare m check_address_validity e1 op e2 =
      match m with
      | BOT -> BOT, Taint.Set.singleton Taint.BOT
      | Val m' ->
         let bot = ref false in
         let mres, t = USet.fold (fun u (m', t) ->
                        try
                          let ulist', tset' = U.compare u check_address_validity e1 op e2 in
                          List.fold_left (fun m' u -> USet.add u m') m' ulist', Taint.Set.singleton tset'
                          with Exceptions.Empty _ ->
                            bot := true;
                            m', t) m' (USet.empty, Taint.Set.singleton Taint.U) 
         in
         let card = USet.cardinal mres in
         if !bot && card = 0 then
           BOT, Taint.Set.singleton Taint.BOT
         else
           if card > !Config.kset_bound then
             Val (merge mres), Taint.Set.singleton (Taint.Set.fold Taint.logor t Taint.U)
           else
             Val mres, t

    let mem_to_addresses m e check_address_validity =
      match m with
      | BOT -> raise (Exceptions.Empty (Printf.sprintf "Environment is empty. Can't evaluate %s" (Asm.string_of_exp e true)))
      | Val m' ->
         USet.fold (fun u (addrs, t) ->
             let addrs', t' = U.mem_to_addresses u e check_address_validity in
             Data.Address.Set.union addrs addrs', Taint.Set.add t' t) m' (Data.Address.Set.empty, Taint.Set.singleton Taint.U)

    let taint_sources e m check_address_validity =
      match m with
      | BOT -> Taint.Set.singleton Taint.BOT
      | Val m' ->  USet.fold (fun u t -> Taint.Set.add (U.taint_sources e u check_address_validity) t) m' Taint.Set.empty

    let get_offset_from e cmp terminator upper_bound sz m check_address_validity =
        match m with
      | BOT -> raise (Exceptions.Empty "Unrels.get_offset_from: environment is empty")
      | Val m' ->
         let res =
           USet.fold (fun u o ->
               let o' = U.get_offset_from e cmp terminator upper_bound sz u check_address_validity in
               match o with
               | None -> Some o'
               | Some o ->
                  if o = o' then Some o
                  else raise (Exceptions.Empty "Unrels.get_offset_from: different offsets found")) m' None
         in
         match res with
         | Some o -> o
         | _ -> raise (Exceptions.Empty "Unrels.get_offset_from: undefined offset")
            
    let get_bytes e cmp terminator (upper_bound: int) (sz: int) (m: t) check_address_validity =
          match m with
      | BOT -> raise (Exceptions.Empty "Unrels.get_bytes: environment is empty")
      | Val m' ->
         let res =
           USet.fold (fun u acc ->
             let len, bytes = U.get_bytes e cmp terminator upper_bound sz u check_address_validity in
             match acc with
             | None -> Some (len, bytes)
             | Some (len', bytes') ->
                if len = len' then
                  if Bytes.equal bytes bytes' then
                    acc
                  else
                    raise (Exceptions.Empty "Unrels.get_bytes: incompatible set of bytes to return")
                else
                  raise (Exceptions.Empty "Unrels.get_bytes: incompatible set of bytes to return")       
             ) m' None
         in
         match res with
         | Some r -> r
         | None -> raise (Exceptions.Empty "Unrels.get_bytes: undefined bytes to compute")

    let copy m dst arg sz check_address_validity =
      match m with
      | Val m' -> Val (USet.map (fun u -> U.copy u dst arg sz check_address_validity) m')
      | BOT -> BOT

    let copy_hex m dst src nb capitalise pad_option word_sz check_address_validity =
      match m with
      | Val m' ->
         let m, n =
           USet.fold (fun u (acc, n) ->
               let u', n' = U.copy_hex u dst src nb capitalise pad_option word_sz check_address_validity in
               let nn =
                 match n with
                 | None -> Some n'
                 | Some n  ->
                    if n = n' then Some n' 
                    else raise (Exceptions.Empty "diffrent lengths of  bytes copied in Unrels.copy_hex")
               in
               USet.add u' acc, nn
             ) m' (USet.empty, None)
         in
         begin
           match n  with
           | Some n' -> Val m, n'
           | None -> raise (Exceptions.Empty "uncomputable length of  bytes copied in Unrels.copy_hex")
         end
      | BOT -> BOT, 0
             
    let print m arg sz check_address_validity =
      match m with
      | Val m' -> USet.iter (fun u -> U.print u arg sz check_address_validity) m'; m
      | BOT -> Log.Stdout.stdout (fun p -> p "_"); m

    let print_hex m src nb capitalise pad_option word_sz check_address_validity =
      match m with
      | BOT -> Log.Stdout.stdout (fun p -> p "_"); m, raise (Exceptions.Empty "Unrels.print_hex: environment is empty")
      | Val m' ->
         match USet.elements m' with
         | [u] ->
            let u', len = U.print_hex u src nb capitalise pad_option word_sz check_address_validity in
            Val (USet.singleton u'), len
         | _ -> raise (Exceptions.Too_many_concrete_elements "U.print_hex: implemented only for one unrel only")

    let copy_until m dst e terminator term_sz upper_bound with_exception pad_options check_address_validity =
       match m with
       | BOT -> 0, BOT
       | Val m' ->
          match USet.elements m' with
          | [u] ->
             let len, u' = U.copy_until u dst e terminator term_sz upper_bound with_exception pad_options check_address_validity in
             len, Val (USet.singleton u')
         | _ -> raise (Exceptions.Too_many_concrete_elements "U.copy_until: implemented only for one unrel only")

    let print_until m e terminator term_sz upper_bound with_exception pad_options check_address_validity =
      match m with
       | BOT -> Log.Stdout.stdout (fun p -> p "_"); 0, BOT
       | Val m' ->
          match USet.elements m' with
          | [u] ->
             let len, u' = U.print_until u e terminator term_sz upper_bound with_exception pad_options check_address_validity in
             len, Val (USet.singleton u')
          | _ -> raise (Exceptions.Too_many_concrete_elements "U.print_until: implemented only for one unrel only")

    let copy_chars m dst src nb pad_options check_address_validity =
      match m with
      | BOT -> BOT
      | Val m' -> Val (USet.map (fun u -> U.copy_chars u dst src nb pad_options check_address_validity) m')

    let print_chars m src nb pad_options check_address_validity =
      match m with
      | Val m' -> Val (USet.map (fun u -> U.print_chars u src nb pad_options check_address_validity) m')
      | BOT -> Log.Stdout.stdout (fun p -> p "_"); BOT

    let copy_register r dst src =
      match src with
      | Val src' ->
         begin
           let dst' =
             match dst with
             | Val dst' -> dst'
             | BOT -> USet.empty
           in
           Val (USet.fold (fun u1 acc ->
                    let acc' = USet.map (fun u2 -> U.copy_register r u1 u2) src' in
                    USet.union acc' acc)
                  dst' USet.empty)
         end
      | BOT -> BOT
              
  end