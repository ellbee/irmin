(*
 * Copyright (c) 2013-2017 Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Result
open Lwt.Infix
open Test_common

let merge_exn msg x = match x with
  | Ok x                -> Lwt.return x
  | Error (`Conflict m) -> failf "%s: %s" msg m

let task msg =
  let date = Int64.of_float (Unix.gettimeofday ()) in
  let owner = Printf.sprintf "TESTS" in
  Irmin.Task.v ~date ~owner msg

let taskf fmt = Fmt.kstrf task fmt

let () = Random.self_init ()
let random_char () = char_of_int (Random.int 256)
let random_ascii () = char_of_int (Random.int 128)

let random_string n = String.init n (fun _i -> random_char ())
let long_random_string = random_string 1024_000

let random_ascii_string n = String.init n (fun _i -> random_ascii ())
let long_random_ascii_string = random_ascii_string 1024_000

module Make (S: Test_S) = struct

  module P = S.Private
  module Graph = Irmin.Private.Node.Graph(P.Node)
  module History = Irmin.Private.Commit.History(P.Commit)

  let v repo = P.Repo.contents_t repo
  let n repo = P.Repo.node_t repo
  let ct repo = P.Repo.commit_t repo
  let g repo = P.Repo.node_t repo
  let h repo = P.Repo.commit_t repo

  let dummy_task =
    let t = Irmin.Task.empty in
    fun () -> t

  let v1 = long_random_string
  let v2 = ""

  let kv1 ~repo = P.Contents.add (P.Repo.contents_t repo) v1
  let kv2 ~repo = P.Contents.add (P.Repo.contents_t repo) v2
  let normal x = `Contents (x, S.Metadata.default)

  let b1 = "foo"
  let b2 = "bar" / "toto"

  let n1 ~repo =
    kv1 ~repo >>= fun kv1 ->
    Graph.v (g repo) ["x", normal kv1]

  let n2 ~repo =
    n1 ~repo >>= fun kn1 ->
    Graph.v (g repo) ["b", `Node kn1]

  let n3 ~repo =
    n2 ~repo >>= fun kn2 ->
    Graph.v (g repo) ["a", `Node kn2]

  let n4 ~repo =
    n1 ~repo >>= fun kn1 ->
    kv2 ~repo >>= fun kv2 ->
    Graph.v (g repo) ["x", normal kv2] >>= fun kn4 ->
    Graph.v (g repo) ["b", `Node kn1; "c", `Node kn4] >>= fun kn5 ->
    Graph.v (g repo) ["a", `Node kn5]

  let r1 ~repo =
    n2 ~repo >>= fun kn2 ->
    History.v (h repo) ~node:kn2 ~parents:[] ~task:Irmin.Task.empty

  let r2 ~repo =
    n3 ~repo >>= fun kn3 ->
    r1 ~repo >>= fun kr1 ->
    History.v (h repo) ~node:kn3 ~parents:[kr1] ~task:Irmin.Task.empty

  let run x test =
    try
      Lwt_main.run (
        x.init () >>= fun () ->
        S.Repo.v x.config >>= fun repo ->
        test repo >>= x.clean
      )
    with e ->
      Lwt_main.run (x.clean ());
      raise e

  let random_value value = random_string value

  let random_path ~label ~path =
    let short () = random_ascii_string label in
    let rec aux = function
      | 0 -> []
      | n -> short () :: aux (n-1)
    in
    aux path

  let random_node ~label ~path ~value =
    random_path ~label ~path, random_value value

  let random_nodes ?(label=8) ?(path=5) ?(value=1024) n =
    let rec aux acc = function
      | 0 -> acc
      | n -> aux (random_node ~label ~path ~value :: acc) (n-1) in
    aux [] n

  let sleep ?(sleep_t=0.01) () =
    let sleep_t = min sleep_t 1. in
    Lwt_unix.yield () >>= fun () ->
    Lwt_unix.sleep sleep_t

  let retry ?(timeout=5. *. 60.) ?(sleep_t=0.) fn =
    let sleep_t = max sleep_t 0.001 in
    let time = Unix.gettimeofday in
    let t = time () in
    let str i = Fmt.strf "%d, %.3fs" i (time () -. t) in
    let rec aux i =
      if time () -. t > timeout then fn (str i);
      try fn (str i); Lwt.return_unit
      with ex ->
        Logs.debug (fun f -> f "retry ex: %s" (Printexc.to_string ex));
        let sleep_t = sleep_t *. (1. +. float i ** 2.) in
        sleep ~sleep_t () >>= fun () ->
        Logs.debug (fun f -> f "Test.retry %s" (str i));
        aux (i+1)
    in
    aux 0

  let old k () = Lwt.return (Ok (Some k))

  let test_contents x () =
    let test repo =
      let t = P.Repo.contents_t repo in
      let check_key = check P.Contents.Key.t in
      let check_val = check (Depyt.option S.contents_t) in
      kv2 ~repo >>= fun kv2 ->
      P.Contents.add t v2 >>= fun k2' ->
      check_key "kv2" kv2 k2';
      P.Contents.find t k2' >>= fun v2' ->
      check_val "v2" (Some v2) v2';

      P.Contents.add t v2 >>= fun k2'' ->
      check_key "kv2" kv2 k2'';

      kv1 ~repo >>= fun kv1 ->
      P.Contents.add t v1 >>= fun k1' ->
      check_key "kv1" kv1 k1';
      P.Contents.add t v1 >>= fun k1'' ->
      check_key "kv1" kv1 k1'';
      P.Contents.find t kv1 >>= fun v1' ->
      check_val "v1" (Some v1) v1';
      P.Contents.find t kv2 >>= fun v2' ->
      check_val "v2" (Some v2) v2';
      Lwt.return_unit
    in
    run x test

  let get = function None -> Alcotest.fail "get" | Some v -> v
  let get_node = function `Node n -> n | _ -> Alcotest.fail "get_node"

  let test_nodes x () =
    let test repo =
      let g = g repo and n = n repo in
      kv1 ~repo >>= fun kv1 ->
      let check_key = check P.Node.Key.t in
      let check_val = check (Depyt.option Graph.value_t) in

      (* Create a node containing t1 -x-> (v1) *)
      Graph.v g ["x", normal kv1] >>= fun k1 ->
      Graph.v g ["x", normal kv1] >>= fun k1' ->
      check_key "k1.1" k1 k1';
      P.Node.find n k1 >>= fun t1 ->
      P.Node.add n (get t1) >>= fun k1''->
      check_key "k1.2" k1 k1'';

      (* Create the node  t2 -b-> t1 -x-> (v1) *)
      Graph.v g ["b", `Node k1] >>= fun k2 ->
      Graph.v g ["b", `Node k1] >>= fun k2' ->
      check_key "k2.1" k2 k2';
      P.Node.find n k2 >>= fun t2 ->
      P.Node.add n (get t2) >>= fun k2''->
      check_key "k2.2" k2 k2'';
      Graph.find g k2 ["b"] >>= fun k1''' ->
      check_val "k1.3" (Some (`Node k1)) k1''';

      (* Create the node t3 -a-> t2 -b-> t1 -x-> (v1) *)
      Graph.v g ["a", `Node k2] >>= fun k3 ->
      Graph.v g ["a", `Node k2] >>= fun k3' ->
      check_key "k3.1" k3 k3';
      P.Node.find n k3 >>= fun t3 ->
      P.Node.add n (get t3) >>= fun k3''->
      check_key "k3.2" k3 k3'';
      Graph.find g k3 ["a"] >>= fun k2'' ->
      check_val "k2.3" (Some (`Node k2)) k2'';

      Graph.find g k2' ["b"] >>= fun k1'''' ->
      check_val "t1.2" (Some (`Node k1)) k1'''';
      Graph.find g k3 ["a";"b"] >>= fun k1'''''->
      check_val "t1.3" (Some (`Node k1)) k1''''';

      Graph.find g k1 ["x"] >>= fun kv11 ->
      check_val "v1.1" (Some (normal kv1)) kv11;
      Graph.find g k2 ["b";"x"] >>= fun kv12 ->
      check_val "v1.2" (Some (normal kv1)) kv12;
      Graph.find g k3 ["a";"b";"x"] >>= fun kv13 ->
      check_val "v1" (Some (normal kv1)) kv13;

      (* Create the node t6 -a-> t5 -b-> t1 -x-> (v1)
                                   \-c-> t4 -x-> (v2) *)
      kv2 ~repo >>= fun kv2 ->
      Graph.v g ["x", normal kv2] >>= fun k4 ->
      Graph.v g ["b", `Node k1; "c", `Node k4] >>= fun k5 ->
      Graph.v g ["a", `Node k5] >>= fun k6 ->
      Graph.update g k3 ["a";"c";"x"] (normal kv2) >>= fun k6' ->
      P.Node.find n k6' >>= fun n6' ->
      P.Node.find n k6  >>= fun n6 ->
      check Depyt.(option P.Node.Val.t) "node n6" n6 n6';
      check_key "node k6" k6 k6';

      let assert_no_duplicates n node =
        let names = ref [] in
        Graph.list g node >|= fun all ->
        List.iter (fun (s, _) ->
            if List.mem s !names then failf "%s: duplicate!" n
            else names := s :: !names
          ) all
      in
      Graph.v g []                >>= fun n0 ->

      Graph.update g n0 ["b"] (`Node n0) >>= fun n1 ->
      Graph.update g n1 ["a"] (`Node n0) >>= fun n2 ->
      Graph.update g n2 ["a"] (`Node n0) >>= fun n3 ->
      assert_no_duplicates "1" n3 >>= fun () ->

      Graph.update g n0 ["a"] (`Node n0) >>= fun n1 ->
      Graph.update g n1 ["b"] (`Node n0) >>= fun n2 ->
      Graph.update g n2 ["a"] (`Node n0) >>= fun n3 ->
      assert_no_duplicates "2" n3 >>= fun () ->

      Graph.update g n0 ["b"] (normal kv1) >>= fun n1 ->
      Graph.update g n1 ["a"] (normal kv1) >>= fun n2 ->
      Graph.update g n2 ["a"] (normal kv1) >>= fun n3 ->
      assert_no_duplicates "3" n3 >>= fun () ->

      Graph.update g n0 ["a"] (normal kv1) >>= fun n1 ->
      Graph.update g n1 ["b"] (normal kv1) >>= fun n2 ->
      Graph.update g n2 ["b"] (normal kv1) >>= fun n3 ->
      assert_no_duplicates "4" n3 >>= fun () ->

      Lwt.return_unit
    in
    run x test

  let test_commits x () =
    let test repo =

      let task date =
        let i = Int64.of_int date in
        Irmin.Task.v ~date:i ~owner:"test" "Test commit" ~uid:i
      in

      kv1 ~repo >>= fun kv1 ->
      let g = g repo and h = h repo and c = P.Repo.commit_t repo in

      let check_val = check (Depyt.option P.Commit.Val.t) in
      let check_key = check P.Commit.Key.t in
      let check_keys = checks P.Commit.Key.t in

      (* t3 -a-> t2 -b-> t1 -x-> (v1) *)
      Graph.v g ["x", normal kv1] >>= fun kt1 ->
      Graph.v g ["a", `Node kt1] >>= fun kt2 ->
      Graph.v g ["b", `Node kt2] >>= fun kt3 ->

      (* r1 : t2 *)
      let with_task n fn = fn h ~task:(task n) in
      with_task 3 @@ History.v ~node:kt2 ~parents:[] >>= fun kr1 ->
      with_task 3 @@ History.v ~node:kt2 ~parents:[] >>= fun kr1' ->
      P.Commit.find c kr1  >>= fun t1 ->
      P.Commit.find c kr1' >>= fun t1' ->
      check_val "t1" t1 t1';
      check_key "kr1" kr1 kr1';

      (* r1 -> r2 : t3 *)
      with_task 4 @@ History.v ~node:kt3 ~parents:[kr1] >>= fun kr2 ->
      with_task 4 @@ History.v ~node:kt3 ~parents:[kr1] >>= fun kr2' ->
      check_key "kr2" kr2 kr2';

      History.closure h ~min:[] ~max:[kr1] >>= fun kr1s ->
      check_keys "g1" [kr1] kr1s;

      History.closure h ~min:[] ~max:[kr2] >>= fun kr2s ->
      check_keys "g2" [kr1; kr2] kr2s;

      if x.kind = `Git then (
        S.Git.git_commit repo kr1 >|= function
        | None   -> Alcotest.fail "cannot read the Git internals"
        | Some c ->
          let name = c.Git.Commit.author.Git.User.name in
          Alcotest.(check string) "author" "test" name;
      ) else (
        Lwt.return_unit
      ) >>= fun () ->

      Lwt.return_unit
    in
    run x test

  let test_branches x () =
    let test repo =
      let check_keys = checks S.Branch.t in
      let check_val = check (Depyt.option S.Commit.t) in

      r1 ~repo >>= fun kv1 ->
      r2 ~repo >>= fun kv2 ->

      line "pre-update";
      S.Branch.set repo b1 kv1 >>= fun () ->
      line "post-update";
      S.Branch.find repo b1 >>= fun k1' ->
      check_val "r1" (Some kv1) k1';
      S.Branch.set repo b2 kv2 >>= fun () ->
      S.Branch.find repo b2 >>= fun k2' ->
      check_val "r2" (Some kv2) k2';
      S.Branch.set repo b1 kv2 >>= fun () ->
      S.Branch.find repo b1 >>= fun k2'' ->
      check_val "r1-after-update" (Some kv2) k2'';

      S.Branch.list repo >>= fun bs ->
      check_keys "list" [b1; b2] bs;
      S.Branch.remove repo b1 >>= fun () ->
      S.Branch.find repo b1 >>= fun empty ->
      check_val "empty" None empty;
      S.Branch.list repo >>= fun b2' ->
      check_keys "all-after-remove" [b2] b2';
      Lwt.return_unit
    in
    run x test

  let test_watch_exn x () =
    let test repo =
      S.master repo >>= fun t ->
      S.Head.find t >>= fun h ->
      let key = ["a"] in
      let v1  = "bar" in
      let v2  = "foo" in
      let r = ref 0 in
      let eq = Irmin.Type.(equal (Irmin.Diff.t S.commit_t)) in
      let old_head = ref h in
      let check x =
        S.Head.get t >|= fun h2 ->
        match !old_head with
        | None   -> if eq (`Added h2) x then incr r
        | Some h -> if eq (`Updated (h, h2)) x then incr r
      in

      S.watch ?init:h t (fun v -> check v >|= fun () -> failwith "test")
      >>= fun u ->
      S.watch ?init:h t (fun v -> check v >>= fun () ->  Lwt.fail_with "test")
      >>= fun v ->
      S.watch ?init:h t (fun v -> check v)
      >>= fun w ->

      S.set t (taskf "update") key v1 >>= fun () ->
      retry (fun n -> Alcotest.(check int) ("watch 1 " ^ n) 3 !r) >>= fun () ->

      S.Head.find t >>= fun h ->
      old_head := h;

      S.set t (taskf "update") key v2 >>= fun () ->
      retry (fun n -> Alcotest.(check int) ("watch 2 " ^ n) 6 !r) >>= fun () ->

      S.unwatch u >>= fun () ->
      S.unwatch v >>= fun () ->
      S.unwatch w >>= fun () ->

      S.Head.get t >>= fun h ->
      old_head := Some h;

      S.watch_key ~init:h t key (fun _ -> incr r; failwith "test")
      >>= fun u ->
      S.watch_key ~init:h t key (fun _ -> incr r; Lwt.fail_with "test")
      >>= fun v ->
      S.watch_key ~init:h t key (fun _ -> incr r; Lwt.return_unit)
      >>= fun w ->
      S.set t (taskf "update") key v1 >>= fun () ->
      retry (fun n -> Alcotest.(check int) ("watch 3 " ^ n) 9 !r) >>= fun () ->
      S.set t (taskf "update") key v2 >>= fun () ->
      retry (fun n -> Alcotest.(check int) ("watch 4 " ^ n) 12 !r) >>= fun () ->
      S.unwatch u >>= fun () ->
      S.unwatch v >>= fun () ->
      S.unwatch w >>= fun () ->

      Alcotest.(check unit) "ok!" () ();
      Lwt.return_unit
    in
    run x test

  let test_watches x () =

    let pp_w ppf (p, w) = Fmt.pf ppf "%d/%d" p w in
    let pp_s ppf = function
      | None   -> Fmt.string ppf ""
      | Some w -> pp_w ppf (w ())
    in

    let check_workers msg p w =
      match x.stats with
      | None       -> Lwt.return_unit
      | Some stats ->
        retry (fun s ->
            let got = stats () in
            let exp = p, w in
            let msg = Fmt.strf "workers: %s %a (%s)" msg pp_w got s in
            if got = exp then line msg
            else (
              Logs.debug (fun f ->
                  f "check-worker: expected %a, got %a" pp_w exp pp_w got);
              failf "%s: %a / %a" msg pp_w got pp_w exp
            ))
    in

    let module State = struct
      type t = {
        mutable adds: int;
        mutable updates: int;
        mutable removes: int;
      }
      let empty () = { adds=0; updates=0; removes=0; }
      let add t = t.adds <- t.adds + 1
      let update t = t.updates <- t.updates + 1
      let remove t = t.removes <- t.removes + 1
      let pretty ppf t = Fmt.pf ppf "%d/%d/%d" t.adds t.updates t.removes
      let xpp ppf (a, u, r) = Fmt.pf ppf "%d/%d/%d" a u r
      let xadd (a, u, r) = (a+1, u, r)
      let xupdate (a, u, r) = (a, u+1, r)
      let xremove (a, u, r) = (a, u, r+1)

      let check ?sleep_t msg (p, w) a b =
        let pp ppf (a, u, r) =
          Fmt.pf ppf "{ adds=%d; updates=%d; removes=%d }" a u r
        in
        check_workers msg p w >>= fun () ->
        retry ?sleep_t (fun s ->
            let b = b.adds, b.updates, b.removes in
            let msg = Fmt.strf "state: %s (%s)" msg s in
            if a = b then line msg
            else failf "%s: %a / %a" msg pp a pp b
          )

      let process ?sleep_t t =
        function head ->
          begin match sleep_t with
            | None   -> Lwt.return_unit
            | Some s -> Lwt_unix.sleep s
          end >>= fun () ->
          let () = match head with
            | `Added _   -> add t
            | `Updated _ -> update t
            | `Removed _ -> remove t
          in
          Lwt.return_unit

      let apply msg state kind fn ?(first=false) on s n =
        let msg mode n w s =
          let kind = match kind with
            | `Add    -> "add"
            | `Update -> "update"
            | `Remove -> "remove"
          in
          let mode = match mode with `Pre -> "[pre-condition]" | `Post -> "" in
          Fmt.strf "%s %s %s %d on=%b expected=%a:%a current=%a:%a"
            mode msg kind n on xpp s pp_w w pretty state pp_s x.stats
        in
        let check mode n w s = check (msg mode n w s) w s state in
        let incr = match kind with
          | `Add -> xadd
          | `Update -> xupdate
          | `Remove -> xremove
        in
        let rec aux pre = function
          | 0 -> Lwt.return_unit
          | i ->
            let pre_w =
              if on then 1, (if i = n && first then 0 else 1) else 0, 0
            in
            let post_w = if on then 1, 1 else 0, 0 in
            let post = if on then incr pre else pre in
            check `Pre (n-i) pre_w pre >>= fun () -> (* check pre-condition *)
            Logs.debug (fun f -> f "[waiting for] %s" (msg `Post (n-i) post_w post));
            fn (n-i) >>= fun () ->
            check `Post (n-i) post_w post >>= fun () -> (* check post-condition *)
            aux post (i-1)
        in
        aux s n

    end in

    let test repo =
      S.master repo >>= fun t1 ->
      S.Repo.v x.config >>= fun repo -> S.master repo >>= fun t2 ->

      Logs.debug (fun f -> f "WATCH");

      let state = State.empty () in
      let sleep_t = 0.02 in
      let process = State.process ~sleep_t state in
      let stops_0 = ref [] in
      let stops_1 = ref [] in
      let rec watch = function
        | 0 -> Lwt.return_unit
        | n ->
          let t = if n mod 2 = 0 then t1 else t2 in
          S.watch t process >>= fun s ->
          if n mod 2 = 0 then stops_0 := s :: !stops_0
          else stops_1 := s :: !stops_1;
          watch (n-1)
      in
      let v1 = "X1" in
      let v2 = "X2" in

      S.set t1 (taskf "update") ["a";"b"] v1 >>= fun () ->
      S.Branch.remove repo S.Branch.master >>= fun () ->
      State.check "init" (0, 0) (0, 0, 0) state >>= fun () ->

      watch 100 >>= fun () ->

      State.check "watches on" (1, 0) (0, 0, 0) state >>= fun () ->

      S.set t1 (taskf "update") ["a";"b"] v1 >>= fun () ->
      State.check "watches adds" (1, 1) (100, 0, 0) state >>= fun () ->

      S.set t2 (taskf "update") ["a";"c"] v1 >>= fun () ->
      State.check "watches updates" (1, 1) (100, 100, 0) state >>= fun () ->

      S.Branch.remove repo S.Branch.master >>= fun () ->
      State.check "watches removes" (1, 1) (100, 100, 100) state >>= fun () ->

      Lwt_list.iter_s (fun f -> S.unwatch f) !stops_0 >>= fun () ->
      S.set t2 (taskf "update") ["a"] v1 >>= fun () ->
      State.check "watches half off" (1, 1) (150, 100, 100) state  >>= fun () ->

      Lwt_list.iter_s (fun f -> S.unwatch f) !stops_1 >>= fun () ->
      S.set t1 (taskf "update") ["a"] v2 >>= fun () ->
      State.check "watches off" (0, 0) (150, 100, 100) state >>= fun () ->

      Logs.debug (fun f -> f "WATCH-ALL");
      let state = State.empty () in

      r1 ~repo >>= fun head ->
      let add = State.apply "branch-watch-all" state `Add (fun n ->
          let tag = Fmt.strf "t%d" n in
          S.Branch.set repo tag head
        ) in
      let remove = State.apply "branch-watch-all" state `Remove (fun n ->
          let tag = Fmt.strf "t%d" n in
          S.Branch.remove repo tag
        ) in

      S.Branch.watch_all repo (fun _ -> State.process state) >>= fun u ->

      add    true (0,  0, 0) 10 ~first:true >>= fun () ->
      remove true (10, 0, 0) 5 >>= fun () ->

      S.unwatch u  >>= fun () ->

      add    false (10, 0, 5) 4 >>= fun () ->
      remove false (10, 0, 5) 4 >>= fun () ->

      Logs.debug (fun f -> f "WATCH-KEY");

      let state = State.empty () in
      let path1 = ["a"; "b"; "c"] in
      let path2 = ["a"; "d"] in
      let path3 = ["a"; "b"; "d"] in
      let add = State.apply "branch-key" state `Add (fun _ ->
          let v = "" in
          S.set t1 (taskf "set1") path1 v >>= fun () ->
          S.set t1 (taskf "set2") path2 v >>= fun () ->
          S.set t1 (taskf "set3") path3 v >>= fun () ->
          Lwt.return_unit
        ) in
      let update = State.apply "branch-key" state `Update (fun n ->
          let v = string_of_int n in
          S.set t2 (taskf "update1") path1 v >>= fun () ->
          S.set t2 (taskf "update2") path2 v >>= fun () ->
          S.set t2 (taskf "update3") path3 v >>= fun () ->
          Lwt.return_unit
        ) in
      let remove = State.apply "branch-key" state `Remove (fun _ ->
          S.remove t1 (taskf "remove1") path1 >>= fun () ->
          S.remove t1 (taskf "remove2") path2 >>= fun () ->
          S.remove t1 (taskf "remove3") path3 >>= fun () ->
          Lwt.return_unit
        ) in

      S.remove t1 (taskf "clean") [] >>= fun () ->

      S.watch_key t1 path1 (State.process state) >>= fun u ->

      add    true (0, 0 , 0) 1  ~first:true >>= fun () ->
      update true (1, 0 , 0) 10 >>= fun () ->
      remove true (1, 10, 0) 1  >>= fun () ->

      S.unwatch u >>= fun () ->

      add    false (1, 10, 1) 3 >>= fun () ->
      update false (1, 10, 1) 5 >>= fun () ->
      remove false (1, 10, 1) 4 >>= fun () ->

      Logs.debug (fun f -> f "WATCH-MORE");

      let state = State.empty () in

      let update = State.apply "watch-more" state `Update (fun n ->
          let v = string_of_int n in
          let path1 = ["a"; "b"; "c"; string_of_int n; "1"] in
          let path2 = ["a"; "x"; "c"; string_of_int n; "1"] in
          let path3 = ["a"; "y"; "c"; string_of_int n; "1"] in
          S.set t2 (taskf "update1") path1 v >>= fun () ->
          S.set t2 (taskf "update2") path2 v >>= fun () ->
          S.set t2 (taskf "update3") path3 v >>= fun () ->
          Lwt.return_unit
        ) in

      S.remove t1 (taskf "remove") ["a"] >>= fun () ->
      S.set t1 (taskf "prepare") ["a";"b";"c"] "" >>= fun () ->

      S.Head.get t1 >>= fun h ->
      S.watch_key t2 ~init:h ["a";"b"] (State.process state) >>= fun u ->

      update true (0, 0, 0) 10 ~first:true >>= fun () ->
      S.unwatch u >>= fun () ->
      update false (0, 10, 0) 10 >>= fun () ->

      Lwt.return_unit
    in
    run x test

  let test_simple_merges x () =

    (* simple merges *)
    let check_merge () =
      let ok = Irmin.Merge.ok in
      let dt = Depyt.(option int) in
      let dx = Depyt.(list (pair string int)) in
      let merge_skip ~old:_ _ _ = ok None in
      let merge_left ~old:_ x _ = ok x in
      let merge_right ~old:_ _ y = ok y in
      let merge_default = Irmin.Merge.default dt in
      let merge = function
        | "left"  -> Irmin.Merge.v dt merge_left
        | "right" -> Irmin.Merge.v dt merge_right
        | "skip"  -> Irmin.Merge.v dt merge_skip
        | _ -> merge_default
      in
      let merge_x = Irmin.Merge.alist Depyt.string Depyt.int merge in
      let old () = ok (Some [ "left", 1; "foo", 2; ]) in
      let x =   [ "left", 2; "right", 0] in
      let y =   [ "left", 1; "bar"  , 3; "skip", 0 ] in
      let m =   [ "left", 2; "bar"  , 3] in
      Irmin.Merge.(f merge_x) ~old x y >>= function
      | Error (`Conflict c) -> failf "conflict %s" c
      | Ok m'               ->
        check dx "compound merge" m m';
        Lwt.return_unit
    in

    let test repo =
      check_merge () >>= fun () ->
      kv1 ~repo >>= fun kv1 ->
      kv2 ~repo >>= fun kv2 ->
      let check_result =
        check (Irmin.Merge.result_t Depyt.(option P.Contents.Key.t))
      in

      (* merge contents *)

      let v = P.Repo.contents_t repo in
      Irmin.Merge.f (P.Contents.merge v)
        ~old:(old (Some kv1)) (Some kv1) (Some kv1)
      >>= fun kv1' ->
      check_result "merge kv1" (Ok (Some kv1)) kv1';

      Irmin.Merge.f (P.Contents.merge v)
        ~old:(old (Some kv1)) (Some kv1) (Some kv2)
      >>= fun kv2' ->
      check_result "merge kv2" (Ok (Some kv2)) kv2';

      (* merge nodes *)

      let g = g repo in

      (* The empty node *)
      Graph.v g [] >>= fun k0 ->

      (* Create the node t1 -x-> (v1) *)
      Graph.v g ["x", normal kv1] >>= fun k1 ->

      (* Create the node t2 -b-> t1 -x-> (v1) *)
      Graph.v g ["b", `Node k1] >>= fun k2 ->

      (* Create the node t3 -c-> t1 -x-> (v1) *)
      Graph.v g ["c", `Node k1] >>= fun k3 ->

      (* Should create the node:
                          t4 -b-> t1 -x-> (v1)
                             \c/ *)
      Irmin.Merge.(f @@ P.Node.merge g)
        ~old:(old (Some k0)) (Some k2) (Some k3) >>= fun k4 ->
      merge_exn "k4" k4 >>= fun k4 ->
      let k4 = match k4 with Some k -> k | None -> failwith "k4" in

      let _ = k4 in

      let succ_t = Depyt.(pair string Graph.value_t) in

      Graph.list g k4 >>= fun succ ->
      checks succ_t "k4"[ ("b", `Node k1); ("c", `Node k1) ] succ;

      let task date =
        let i = Int64.of_int date in
        Irmin.Task.v ~date:i ~uid:i ~owner:"test" "Test commit"
      in

      let h = h repo and c = P.Repo.commit_t repo in
      let with_task n fn = fn h ~task:(task n) in

      with_task 0 @@ History.v ~node:k0 ~parents:[] >>= fun kr0 ->
      with_task 1 @@ History.v ~node:k2 ~parents:[kr0] >>= fun kr1 ->
      with_task 2 @@ History.v ~node:k3 ~parents:[kr0] >>= fun kr2 ->
      with_task 3 (fun h ~task ->
          Irmin.Merge.f @@ History.merge h ~task
        ) ~old:(old kr0) kr1 kr2 >>= fun kr3 ->
      merge_exn "kr3" kr3 >>= fun kr3 ->

      with_task 4 (fun h ~task ->
          Irmin.Merge.f @@ History.merge h ~task
        ) ~old:(old kr2) kr2 kr3 >>= fun kr3_id' ->
      merge_exn "kr3_id'" kr3_id' >>= fun kr3_id' ->
      check S.Commit.t "kr3 id with immediate parent'" kr3 kr3_id';

      with_task 5 (fun h ~task ->
          Irmin.Merge.f @@ History.merge h ~task
        ) ~old:(old kr0) kr0 kr3 >>= fun kr3_id ->
      merge_exn "kr3_id" kr3_id >>= fun kr3_id ->
      check S.Commit.t "kr3 id with old parent" kr3 kr3_id;

      with_task 3 @@ History.v ~node:k4 ~parents:[kr1; kr2] >>= fun kr3' ->

      P.Commit.find c kr3 >>= fun r3 ->
      P.Commit.find c kr3' >>= fun r3' ->
      check Depyt.(option P.Commit.Val.t) "r3" r3 r3';
      check S.Commit.t "kr3" kr3 kr3';
      Lwt.return_unit
    in
    run x test

  let test_history x () =
    let test repo =
      let task date =
        let i = Int64.of_int date in
        Irmin.Task.v ~date:i ~uid:i ~owner:"test" "Test commit"
      in
      let h = h repo in
      Graph.v (g repo) [] >>= fun node ->
      let assert_lcas_err msg err l2 =
        let str = function
          | `Too_many_lcas    -> "Too_many_lcas"
          | `Max_depth_reached -> "Max_depth_reached"
        in
        let l2 = match l2 with
          | `Ok x -> failf "%s: %a" msg Fmt.Dump.(list S.Commit.pp) x
          | `Too_many_lcas | `Max_depth_reached as x -> str x
        in
        Alcotest.(check string) msg (str err) l2
      in
      let assert_lcas msg l1 l2 =
        let l2 = match l2 with
          | `Ok x -> x
          | `Too_many_lcas     -> failf "%s: Too many LCAs" msg
          | `Max_depth_reached -> failf "%s: max depth reached" msg
        in
        checks S.Commit.t msg l1 l2
      in
      let assert_lcas msg ~max_depth n a b expected =
        S.of_commit repo a >>= fun a ->
        S.of_commit repo b >>= fun b ->
        S.lcas ~max_depth ~n a b >>= fun lcas ->
        assert_lcas msg expected lcas;
        S.lcas ~max_depth:(max_depth - 1) ~n a b >>= fun lcas ->
        let msg = Printf.sprintf "%s [max-depth=%d]" msg (max_depth - 1) in
        assert_lcas_err msg `Max_depth_reached lcas;
        Lwt.return_unit
      in
      let with_task n fn =
        fn h ~task:(task n) in

      (* test that we don't compute too many lcas

         0->1->2->3->4

      *)
      with_task 0 @@ History.v ~node ~parents:[]   >>= fun k0 ->
      with_task 1 @@ History.v ~node ~parents:[k0] >>= fun k1 ->
      with_task 2 @@ History.v ~node ~parents:[k1] >>= fun k2 ->
      with_task 3 @@ History.v ~node ~parents:[k2] >>= fun k3 ->
      with_task 4 @@ History.v ~node ~parents:[k3] >>= fun k4 ->

      assert_lcas "line lcas 1" ~max_depth:0 3 k3 k4 [k3] >>= fun () ->
      assert_lcas "line lcas 2" ~max_depth:1 3 k2 k4 [k2] >>= fun () ->
      assert_lcas "line lcas 3" ~max_depth:2 3 k1 k4 [k1] >>= fun () ->

      (* test for multiple lca

         4->10--->11-->13-->15
             |      \______/___
             |       ____/     \
             |      /           \
             \--->12-->14-->16-->17

      *)
      with_task 10 @@ History.v ~node ~parents:[k4]       >>= fun k10 ->
      with_task 11 @@ History.v ~node ~parents:[k10]      >>= fun k11 ->
      with_task 12 @@ History.v ~node ~parents:[k10]      >>= fun k12 ->
      with_task 13 @@ History.v ~node ~parents:[k11]      >>= fun k13 ->
      with_task 14 @@ History.v ~node ~parents:[k12]      >>= fun k14 ->
      with_task 15 @@ History.v ~node ~parents:[k12; k13] >>= fun k15 ->
      with_task 16 @@ History.v ~node ~parents:[k14]      >>= fun k16 ->
      with_task 17 @@ History.v ~node ~parents:[k11; k16] >>= fun k17 ->

      assert_lcas "x lcas 0" ~max_depth:0 5 k10 k10 [k10]      >>= fun () ->
      assert_lcas "x lcas 1" ~max_depth:0 5 k14 k14 [k14]      >>= fun () ->
      assert_lcas "x lcas 2" ~max_depth:0 5 k10 k11 [k10]      >>= fun () ->
      assert_lcas "x lcas 3" ~max_depth:1 5 k12 k16 [k12]      >>= fun () ->
      assert_lcas "x lcas 4" ~max_depth:1 5 k10 k13 [k10]      >>= fun () ->
      assert_lcas "x lcas 5" ~max_depth:2 5 k13 k14 [k10]      >>= fun () ->
      assert_lcas "x lcas 6" ~max_depth:3 5 k15 k16 [k12]      >>= fun () ->
      assert_lcas "x lcas 7" ~max_depth:3 5 k15 k17 [k11; k12] >>= fun () ->

      (* lcas on non transitive reduced graphs

                  /->16
                 |
         4->10->11->12->13->14->15
                 |        \--|--/
                 \-----------/
      *)
      with_task 10 @@ History.v ~node ~parents:[k4]      >>= fun k10 ->
      with_task 11 @@ History.v ~node ~parents:[k10]     >>= fun k11 ->
      with_task 12 @@ History.v ~node ~parents:[k11]     >>= fun k12 ->
      with_task 13 @@ History.v ~node ~parents:[k12]     >>= fun k13 ->
      with_task 14 @@ History.v ~node ~parents:[k11;k13] >>= fun k14 ->
      with_task 15 @@ History.v ~node ~parents:[k13;k14] >>= fun k15 ->
      with_task 16 @@ History.v ~node ~parents:[k11]     >>= fun k16 ->

      assert_lcas "weird lcas 1" ~max_depth:0 3 k14 k15 [k14] >>= fun () ->
      assert_lcas "weird lcas 2" ~max_depth:0 3 k13 k15 [k13] >>= fun () ->
      assert_lcas "weird lcas 3" ~max_depth:1 3 k12 k15 [k12] >>= fun () ->
      assert_lcas "weird lcas 4" ~max_depth:1 3 k11 k15 [k11] >>= fun () ->
      assert_lcas "weird lcas 4" ~max_depth:3 3 k15 k16 [k11] >>= fun () ->

      (* fast-forward *)
      S.of_commit repo k12 >>= fun t12  ->
      S.Head.fast_forward t12 k16 >>= fun b1 ->
      Alcotest.(check bool) "ff 1.1" false b1;
      S.Head.get t12 >>= fun k12' ->
      check S.Commit.t "ff 1.2" k12 k12';

      S.Head.fast_forward t12 ~n:1 k14 >>= fun b2 ->
      Alcotest.(check bool) "ff 2.1" false b2;
      S.Head.get t12 >>= fun k12'' ->
      check S.Commit.t "ff 2.3" k12 k12'';

      S.Head.fast_forward t12 k14 >>= fun b3 ->
      Alcotest.(check bool) "ff 2.2" true b3;
      S.Head.get t12 >>= fun k14' ->
      check S.Commit.t "ff 2.3" k14 k14';

      Lwt.return_unit
    in
    run x test

  let test_empty x () =
    let test repo =
      S.empty repo >>= fun t ->
      S.Head.find t >>= fun h ->
      check Depyt.(option S.Commit.t) "empty" None h;
      r1 ~repo >>= fun r1 ->
      S.set t (dummy_task ()) ["b"; "x"] v1 >>= fun () ->
      S.Head.find t >>= fun h ->
      check Depyt.(option S.Commit.t) "not empty" (Some r1) h;
      Lwt.return_unit
    in
    run x test

  let test_slice x () =
    let test repo =
      S.master repo >>= fun t ->
      let a = "" in
      let b = "haha" in
      S.set t (taskf "slice") ["x";"a"] a >>= fun () ->
      S.set t (taskf "slice") ["x";"b"] b >>= fun () ->
      S.Repo.export repo >>= fun slice ->
      let str = Fmt.(to_to_string @@ Depyt.pp_json P.Slice.t) slice in
      let slice' =
        match
          Depyt.decode_json P.Slice.t (Jsonm.decoder (`String str))
        with
        | Ok t    -> t
        | Error e -> Alcotest.fail e
      in
      check P.Slice.t "slices" slice slice';

      Lwt.return_unit
    in
    run x test

  let test_private_nodes x () =
    let test repo =
      let check_val = check Depyt.(option S.contents_t) in
      let vx = "VX" in
      let vy = "VY" in
      S.master repo >>= fun t ->
      S.set t (taskf "add x/y/z") ["x";"y";"z"] vx >>= fun () ->
      S.getv t ["x"] >>= fun view ->
      S.setv t (taskf "update") ["u"] view >>= fun () ->
      S.find t ["u";"y";"z"] >>= fun vx' ->
      check_val "vx" (Some vx) vx';

      S.Head.get t >>= fun head ->
      S.getv t ["u"] >>= fun view ->
      S.set t (taskf "add u/x/y") ["u";"x";"y"] vy >>= fun () ->
      S.Tree.add view ["x";"z"] vx >>= fun view' ->

      S.mergev t (taskf "merge") ["u"] ~parents:[head] view' >>= fun v ->
      merge_exn "v" v >>= fun () ->
      S.find t ["u";"x";"y"] >>= fun vy' ->
      check_val "vy after merge" (Some vy) vy';

      S.find t ["u";"x";"z"] >>= fun vx' ->
      check_val "vx after merge" (Some vx) vx';
      Lwt.return_unit
    in
    run x test

  let test_stores x () =
    let test repo =
      let check_val = check Depyt.(option S.contents_t) in
      let check_list = checks Depyt.(pair S.Key.step_t S.kind_t) in
      S.master repo >>= fun t ->
      S.set t (taskf "init") ["a";"b"] v1 >>= fun () ->
      S.clone ~src:t ~dst:"test" >>= fun t ->
      S.mem t ["a";"b"] >>= fun b1 ->
      Alcotest.(check bool) "mem1" true b1;
      S.mem t ["a"] >>= fun b2 ->
      Alcotest.(check bool) "mem2" false b2;
      S.find t ["a";"b"] >>= fun v1' ->
      check_val "v1.1" (Some v1) v1';

      S.Head.get t >>= fun r1 ->
      S.clone ~src:t ~dst:"test" >>= fun t ->

      S.set t (taskf "update") ["a";"c"] v2 >>= fun () ->
      S.mem t ["a";"b"] >>= fun b1 ->
      Alcotest.(check bool) "mem3" true b1;
      S.mem t ["a"] >>= fun b2 ->
      Alcotest.(check bool) "mem4" false b2;
      S.find t ["a";"b"] >>= fun v1' ->
      check_val "v1.1" (Some v1) v1';
      S.mem t ["a";"c"] >>= fun b1 ->
      Alcotest.(check bool) "mem5" true b1;
      S.find t ["a";"c"] >>= fun v2' ->
      check_val "v1.1" (Some v2) v2';

      S.remove t (taskf "remove") ["a";"b"] >>= fun () ->
      S.find t ["a";"b"] >>= fun v1''->
      check_val "v1.2" None v1'';
      S.Head.set t r1 >>= fun () ->
      S.find t ["a";"b"] >>= fun v1''->
      check_val "v1.3" (Some v1) v1'';
      S.list t ["a"] >>= fun ks ->
      check_list "path" ["b", `Contents] ks;

      S.set t (taskf "update2") ["a"; long_random_ascii_string] v1 >>= fun () ->

      S.remove t (taskf "remove rec") ["a"] >>= fun () ->
      S.list t [] >>= fun dirs ->
      check_list "remove rec" [] dirs;

      Lwt.catch
        (fun () ->
           S.set t (taskf "update root") [] v1 >>= fun () ->
           Alcotest.fail "update root")
        (function
          | Invalid_argument _ -> Lwt.return_unit
          | e -> Alcotest.fail ("update root: " ^ Printexc.to_string e))
      >>= fun () ->
      S.find t [] >>= fun none ->
      check_val "read root" none None;

      S.set t (taskf "update") ["a"] v1 >>= fun () ->
      S.remove t (taskf "remove rec --all") [] >>= fun () ->
      S.list t [] >>= fun dirs ->
      check_list "remove rec root" [] dirs;

      let a = "ok" in
      let b = "maybe?" in

      S.set t (taskf "fst one") ["fst"] a        >>= fun () ->
      S.set t (taskf "snd one") ["fst"; "snd"] b >>= fun () ->

      S.find t ["fst"] >>= fun fst ->
      check_val "data model 1" None fst;
      S.find t ["fst"; "snd"] >>= fun snd ->
      check_val "data model 2" (Some b) snd;

      S.set t (taskf "fst one") ["fst"] a >>= fun () ->

      S.find t ["fst"] >>= fun fst ->
      check_val "data model 3" (Some a) fst;
      S.find t ["fst"; "snd"] >>= fun snd ->
      check_val "data model 4" None snd;

      let tagx = "x" in
      let tagy = "y" in
      let xy = ["x";"y"] in
      let vx = "VX" in
      S.of_branch repo tagx >>= fun tx ->
      S.Branch.remove repo tagx >>= fun () ->
      S.Branch.remove repo tagy >>= fun () ->

      S.set tx (taskf "update") xy vx >>= fun () ->
      S.clone ~src:tx ~dst:tagy >>= fun ty ->
      S.find ty xy >>= fun vx' ->
      check_val "update tag" (Some vx) vx';

      S.status tx |> fun tagx' ->
      S.status ty |> fun tagy' ->
      check S.Status.t "tagx" (`Branch tagx) tagx';
      check S.Status.t "tagy" (`Branch tagy) tagy';

      Lwt.return_unit
    in
    run x test

  let test_views x () =
    let test repo =
      S.master repo >>= fun t ->
      let nodes = random_nodes 100 in
      let foo1 = random_value 10 in
      let foo2 = random_value 10 in

      (* Testing [View.remove] *)

      S.Tree.empty |> fun v1 ->

      S.Tree.add v1 ["foo";"1"] foo1 >>= fun v1 ->
      S.Tree.add v1 ["foo";"2"] foo2 >>= fun v1 ->
      S.Tree.remove v1 ["foo";"1"] >>= fun v1 ->
      S.Tree.remove v1 ["foo";"2"] >>= fun v1 ->

      S.setv t (taskf "empty view") [] v1 >>= fun () ->
      S.Head.get t >>= fun head   ->
      P.Commit.find (ct repo) head >>= fun commit ->
      let node = P.Commit.Val.node (get commit) in
      P.Node.find (n repo) node >>= fun node ->
      check Depyt.(option P.Node.Val.t) "empty view" (Some P.Node.Val.empty) node;

      (* Testing [View.diff] *)

      let contents = Depyt.pair S.contents_t S.metadata_t in
      let diff = Depyt.(pair S.key_t (Irmin.Diff.t contents)) in
      let check_diffs = checks diff in
      let check_val = check Depyt.(option contents) in
      let check_ls = check Depyt.(list (pair S.step_t S.kind_t)) in
      let normal c = Some (c, S.Metadata.default) in
      let d0 = S.Metadata.default in

      S.Tree.empty |> fun v0 ->
      S.Tree.empty |> fun v1 ->
      S.Tree.empty |> fun v2 ->
      S.Tree.add v1 ["foo";"1"] foo1 >>= fun v1 ->
      S.Tree.findm v1 ["foo"; "1"] >>= fun f ->
      check_val "view udate" (normal foo1) f;

      S.Tree.add v2 ["foo";"1"] foo2 >>= fun v2 ->
      S.Tree.add v2 ["foo";"2"] foo1 >>= fun v2 ->

      S.Tree.diff v0 v1 >>= fun d1 ->
      check_diffs "diff 1" [ ["foo";"1"], `Added (foo1, d0) ] d1;

      S.Tree.diff v1 v0 >>= fun d2 ->
      check_diffs "diff 2" [ ["foo";"1"], `Removed (foo1, d0) ] d2;

      S.Tree.diff v1 v2 >>= fun d3 ->
      check_diffs "diff 2" [ ["foo";"1"], `Updated ((foo1, d0), (foo2, d0));
                             ["foo";"2"], `Added (foo1, d0)] d3;

      (* Testing other View operations. *)

      S.Tree.empty |> fun v0 ->

      S.Tree.add v0 [] foo1 >>= fun v0 ->
      S.Tree.findm v0 [] >>= fun foo1' ->
      check_val "read /" (normal foo1) foo1';

      S.Tree.add v0 ["foo";"1"] foo1 >>= fun v0 ->
      S.Tree.findm v0 ["foo";"1"] >>= fun foo1' ->
      check_val "read foo/1" (normal foo1) foo1';

      S.Tree.add v0 ["foo";"2"] foo2 >>= fun v0 ->
      S.Tree.findm v0 ["foo";"2"] >>= fun foo2' ->
      check_val "read foo/2" (normal foo2) foo2';

      let check_view v =
        S.Tree.list v ["foo"] >>= fun ls ->
        check_ls "path1" [ ("1", `Contents); ("2", `Contents) ] ls;
        S.Tree.findm v ["foo";"1"] >>= fun foo1' ->
        check_val "foo1" (normal foo1) foo1';
        S.Tree.findm v ["foo";"2"] >>= fun foo2' ->
        check_val "foo2" (normal foo2) foo2';
        Lwt.return_unit
      in

      Lwt_list.fold_left_s (fun v0 (k,v) ->
          S.Tree.add v0 k v
        ) v0 nodes >>= fun v0 ->
      check_view v0 >>= fun () ->

      S.setv t (taskf "update_path b/") ["b"] v0 >>= fun () ->
      S.setv t (taskf "update_path a/") ["a"] v0 >>= fun () ->

      S.list t ["b";"foo"] >>= fun ls ->
      check_ls "path2" [ "1", `Contents; "2", `Contents] ls;
      S.findm t ["b";"foo";"1"] >>= fun foo1' ->
      check_val "foo1" (normal foo1) foo1';
      S.findm t ["a";"foo";"2"] >>= fun foo2' ->
      check_val "foo2" (normal foo2) foo2';

      S.Head.get t >>= fun head ->
      S.getv t ["b"] >>= fun v1 ->
      check_view v1 >>= fun () ->

      S.set t (taskf "update b/x") ["b";"x"] foo1 >>= fun () ->
      S.Tree.add v1 ["y"] foo2 >>= fun v1 ->
      S.mergev t (taskf "merge_path") ~parents:[head] ["b"] v1 >>=
      merge_exn "merge_path" >>= fun () ->
      S.findm t ["b";"x"] >>= fun foo1' ->
      S.findm t ["b";"y"] >>= fun foo2' ->
      check_val "merge: b/x" (normal foo1) foo1';
      check_val "merge: b/y" (normal foo2) foo2';

      Lwt_list.iteri_s (fun i (k, v) ->
          S.findm t ("a" :: k) >>= fun v' ->
          check_val ("a"^string_of_int i) (normal v) v';
          S.findm t ("b" ::  k) >>= fun v' ->
          check_val ("b"^string_of_int i) (normal v) v';
          Lwt.return_unit
        ) nodes >>= fun () ->

      S.getv t ["b"] >>= fun v2 ->
      S.Tree.findm v2 ["foo"; "1"] >>= fun _ ->
      S.Tree.add v2 ["foo"; "1"] foo2 >>= fun v2 ->
      S.setv t (taskf"v2") ["b"] v2 >>= fun () ->
      S.findm t ["b";"foo";"1"] >>= fun foo2' ->
      check_val "update view" (normal foo2) foo2';

      S.getv t ["b"] >>= fun v3 ->
      S.Tree.findm v3 ["foo"; "1"] >>= fun _ ->
      S.Tree.remove v3 ["foo"; "1"] >>= fun v3 ->
      S.setv t (taskf "v3") ["b"] v3 >>= fun () ->
      S.findm t ["b";"foo";"1"] >>= fun foo2' ->
      check_val "remove view" None foo2';

      r1 ~repo >>= fun r1 ->
      r2 ~repo >>= fun r2 ->
      let ta = Irmin.Task.empty in

      S.setv t Irmin.Task.empty ~parents:[r1;r2] [] v3 >>= fun () ->
      S.Head.get t >>= fun h ->

      S.Repo.task_of_commit repo h >>= fun ta' ->
      check Depyt.(option Irmin.Task.t) "task" (Some ta) ta';

      S.of_commit repo h >>= fun tt ->
      S.history tt >>= fun g ->
      let pred = S.History.pred g h in
      checks S.commit_t "head" [r1;r2] pred;

      S.findm tt ["b";"foo";"1"] >>= fun foo2'' ->
      check_val "remove tt" None foo2'';

      let vx = "VX" in
      let px = ["x";"y";"z"] in
      S.set tt (taskf "update") px vx >>= fun () ->
      S.getv tt [] >>= fun view ->
      S.Tree.findm view px >>= fun vx' ->
      check_val "updates" (normal vx) vx';

      S.Tree.empty |> fun v ->
      S.Tree.add v [] vx >>= fun v ->
      S.setv t (taskf "update file as view") ["a"] v >>= fun () ->
      S.findm t ["a"] >>= fun vx' ->
      check_val "update file as view" (normal vx) vx';

      Lwt.return_unit
    in
    run x test

  module Sync = Irmin.Sync(S)

  let test_sync x () =
    let test repo =
      S.master repo >>= fun t1 ->

      S.set t1 (taskf "update a/b") ["a";"b"] v1 >>= fun () ->
      S.Head.get t1 >>= fun h ->
      S.Head.get t1 >>= fun _r1 ->
      S.set t1 (taskf "update a/c") ["a";"c"] v2 >>= fun () ->
      S.Head.get t1 >>= fun r2 ->
      S.set t1 (taskf "update a/d") ["a";"d"] v1 >>= fun () ->
      S.Head.get t1 >>= fun _r3 ->

      S.history t1 ~min:[h] >>= fun h ->
      Alcotest.(check int) "history-v" 3 (S.History.nb_vertex h);
      Alcotest.(check int) "history-e" 2 (S.History.nb_edges h);

      let remote = Irmin.remote_store (module S) t1 in

      Sync.fetch_exn t1 ~depth:0 remote >>= fun partial ->
      Sync.fetch_exn t1 remote >>= fun full ->

      (* Restart a fresh store and import everything in there. *)
      let tag = "export" in
      S.of_branch repo tag >>= fun t2 ->
      S.Head.set t2 partial >>= fun () ->

      S.mem t2 ["a";"b"] >>= fun b1 ->
      Alcotest.(check bool) "mem-ab" true b1;

      S.mem t2 ["a";"c"] >>= fun b2 ->
      Alcotest.(check bool) "mem-ac" true b2;

      S.mem t2 ["a";"d"] >>= fun b3 ->
      Alcotest.(check bool) "mem-ad" true b3;
      S.get t2 ["a";"d"] >>= fun v1' ->
      check S.contents_t "v1" v1 v1';

      S.Head.set t2 r2 >>= fun () ->
      S.mem t2 ["a";"d"] >>= fun b4 ->
      Alcotest.(check bool) "mem-ab" false b4;

      S.Head.set t2 full >>= fun () ->
      S.Head.set t2 r2 >>= fun () ->
      S.mem t2 ["a";"d"] >>= fun b4 ->
      Alcotest.(check bool) "mem-ad" false b4;
      Lwt.return_unit
    in
    run x test

  module Dot = Irmin.Dot(S)

  let output_file t file =
    let buf = Buffer.create 1024 in
    let date d =
      let tm = Unix.localtime (Int64.to_float d) in
      Fmt.strf "%2d:%2d:%2d" tm.Unix.tm_hour tm.Unix.tm_min tm.Unix.tm_sec
    in
    Dot.output_buffer t ~date buf >>= fun () ->
    let oc = open_out_bin (file ^ ".dot") in
    output_string oc (Buffer.contents buf);
    close_out oc;
    Lwt.return_unit

  let test_merge x () =
    let test repo =
      let v1 = "X1" in
      let v2 = "X2" in
      let v3 = "X3" in

      S.master repo >>= fun t1 ->

      S.set t1 (taskf "update a/b/a") ["a";"b";"a"] v1 >>= fun () ->
      S.set t1 (taskf "update a/b/b") ["a";"b";"b"] v2 >>= fun () ->
      S.set t1 (taskf "update a/b/c") ["a";"b";"c"] v3 >>= fun () ->

      let test = "test" in

      S.clone ~src:t1 ~dst:test >>= fun t2 ->

      S.set t1 (taskf "update master:a/b/b") ["a";"b";"b"] v1 >>= fun () ->
      S.set t1 (taskf "update master:a/b/b") ["a";"b";"b"] v3 >>= fun () ->
      S.set t2 (taskf "update test:a/b/c")   ["a";"b";"c"] v1 >>= fun () ->

      output_file t1 "before" >>= fun () ->
      S.merge (taskf "merge test into master") t2 ~into:t1 >>= fun m ->
      merge_exn "m" m >>= fun () ->
      output_file t1 "after" >>= fun () ->

      S.get t1 ["a";"b";"c"] >>= fun v1' ->
      S.get t2 ["a";"b";"b"] >>= fun v2' ->
      S.get t1 ["a";"b";"b"] >>= fun v3' ->

      check S.contents_t "v1" v1 v1';
      check S.contents_t "v2" v2 v2';
      check S.contents_t "v3" v3 v3';

      Lwt.return_unit
    in
    run x test

  let test_merge_unrelated x () =
    run x @@ fun repo ->
    let v1 = "X1" in
    S.of_branch repo "foo" >>= fun foo ->
    S.of_branch repo "bar" >>= fun bar ->
    S.set foo (taskf "update foo:a") ["a"] v1 >>= fun () ->
    S.set bar (taskf "update bar:b") ["b"] v1 >>= fun () ->
    S.merge (taskf "merge bar into foo") bar ~into:foo >>=
    merge_exn "merge unrelated"

  let rec write fn = function
    | 0 -> Lwt.return_unit
    | i -> (fn i >>= Lwt_unix.yield) <&> write fn (i-1)

  let rec read fn check = function
    | 0 -> Lwt.return_unit
    | i ->
      fn i >>= fun v ->
      check i v;
      read fn check (i-1)

  let test_concurrent_low x () =
    let test_branches repo =
      let k = b1 in
      r1 ~repo >>= fun v ->
      let write = write (fun _i -> S.Branch.set repo k v) in
      let read =
        read
          (fun _i -> S.Branch.find repo k >|= get)
          (fun i  -> check S.commit_t (Fmt.strf "tag %d" i) v)
      in
      write 1 >>= fun () ->
      Lwt.join [ write 10; read 10; write 10; read 10; ]
    in
    let test_contents repo =
      kv2 ~repo >>= fun k ->
      let v = v2 in
      let t = P.Repo.contents_t repo in
      let write =
        write (fun _i -> P.Contents.add t v >>= fun _ -> Lwt.return_unit)
      in
      let read =
        read
          (fun _i -> P.Contents.find t k >|= get)
          (fun i  -> check S.contents_t (Fmt.strf "contents %d" i) v)
      in
      write 1 >>= fun () ->
      Lwt.join [ write 10; read 10; write 10; read 10; ]
    in
    run x (fun repo -> Lwt.join [test_branches repo; test_contents repo])

  let test_concurrent_updates x () =
    let test_one repo =
      let k = ["a";"b";"d"] in
      let v = "X1" in
      S.master repo >>= fun t1 ->
      S.master repo >>= fun t2 ->
      let write t = write (fun i -> S.set t (taskf "update: one %d" i) k v) in
      let read t =
        read
          (fun _ -> S.get t k)
          (fun i -> check S.contents_t (Fmt.strf "update: one %d" i) v)
      in
      Lwt.join [ write t1 10; write t2 10 ] >>= fun () ->
      Lwt.join [ read t1 10 ]
    in
    let test_multi repo =
      let k i = ["a";"b";"c"; string_of_int i ] in
      let v i = Fmt.strf "X%d" i in
      S.master repo >>= fun t1 ->
      S.master repo >>= fun t2 ->
      let write t =
        write (fun i -> S.set t (taskf "update: multi %d" i) (k i) (v i))
      in
      let read t =
        read
          (fun i -> S.get t (k i))
          (fun i -> check S.contents_t (Fmt.strf "update: multi %d" i) (v i))
      in
      Lwt.join [ write t1 10; write t2 10 ] >>= fun () ->
      Lwt.join [ read t1 10 ]
    in
    run x (fun repo ->
        test_one   repo >>= fun () ->
        test_multi repo >>= fun () ->
        Lwt.return_unit
      )

  let test_concurrent_merges x () =
    let test repo =
      let k i = ["a";"b";"c"; string_of_int i ] in
      let v i = Fmt.strf "X%d" i in
      S.master repo >>= fun t1 ->
      S.master repo >>= fun t2 ->
      let write t n =
        write (fun i ->
            let tag = Fmt.strf "tmp-%d-%d" n i in
            S.clone ~src:t ~dst:tag >>= fun m ->
            S.set m (taskf "update") (k i) (v i) >>= fun () ->
            Lwt_unix.yield () >>= fun () ->
            S.merge (taskf "update: multi %d" i) m ~into:t >>=
            merge_exn "update: multi"
          )
      in
      let read t =
        read
          (fun i -> S.get t (k i))
          (fun i -> check S.contents_t (Fmt.strf "update: multi %d" i) (v i))
      in
      S.set t1 (taskf "update") (k 0) (v 0) >>= fun () ->
      Lwt.join [ write t1 1 10; write t2 2 10 ] >>= fun () ->
      Lwt.join [ read t1 10 ]
    in
    run x test

  let test_concurrent_head_updates x () =
    let test repo =
      let k i = ["a";"b";"c"; string_of_int i ] in
      let v i = Fmt.strf "X%d" i in
      S.master repo >>= fun t1 ->
      S.master repo >>= fun t2 ->
      let retry d fn =
        let rec aux i =
          fn () >>= function
          | true  -> Logs.debug (fun f -> f "%d: ok!" d); Lwt.return_unit
          | false ->
            Logs.debug (fun f -> f "%d: conflict, retrying (%d)." d i);
            aux (i+1)
        in
        aux 1
      in
      let write t n =
        write (fun i -> retry i (fun () ->
            S.Head.find t >>= fun test ->
            let tag = Fmt.strf "tmp-%d-%d" n i in
            S.clone ~src:t ~dst:tag >>= fun m ->
            S.set m (taskf "update") (k i) (v i) >>= fun () ->
            S.Head.find m >>= fun set ->
            Lwt_unix.yield () >>= fun () ->
            S.Head.test_and_set t ~test ~set
          ))
      in
      let read t =
        read
          (fun i -> S.get t (k i))
          (fun i -> check S.contents_t (Fmt.strf "update: multi %d" i) (v i))
      in
      S.set t1 (taskf "update") (k 0) (v 0) >>= fun () ->
      Lwt.join [ write t1 1 5; write t2 2 5 ] >>= fun () ->
      Lwt.join [ read t1 5 ]
    in
    run x test

end

let suite (speed, x) =
  let (module S) = x.store in
  let module T = Make(S) in
  x.name,
  [
    "Basic operations on contents"    , speed, T.test_contents x;
    "Basic operations on nodes"       , speed, T.test_nodes x;
    "Basic operations on commits"     , speed, T.test_commits x;
    "Basic operations on branches"    , speed, T.test_branches x;
    "Watch callbacks and exceptions"  , speed, T.test_watch_exn x;
    "Basic operations on watches"     , speed, T.test_watches x;
    "Basic merge operations"          , speed, T.test_simple_merges x;
    "Basic operations on slices"      , speed, T.test_slice x;
    "Complex histories"               , speed, T.test_history x;
    "Empty stores"                    , speed, T.test_empty x;
    "Private node manipulation"       , speed, T.test_private_nodes x;
    "High-level store operations"     , speed, T.test_stores x;
    "High-level operations on views"  , speed, T.test_views x;
    "High-level store synchronisation", speed, T.test_sync x;
    "High-level store merges"         , speed, T.test_merge x;
    "Unrelated merges"                , speed, T.test_merge_unrelated x;
    "Low-level concurrency"           , speed, T.test_concurrent_low x;
    "Concurrent updates"              , speed, T.test_concurrent_updates x;
    "Concurrent head updates"         , speed, T.test_concurrent_head_updates x;
    "Concurrent merges"               , speed, T.test_concurrent_merges x;
  ]

let run name ~misc tl =
  let tl = List.map suite tl in
  Alcotest.run name (tl @ misc)
