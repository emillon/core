open! Core
open! Import
module Unix = Core_unix

let default_command_name = "CMD"

let parse_command_line_raw ~path ~summary param args =
  let name, path =
    match path with
    | None | Some [] -> default_command_name, []
    | Some (hd :: tl) -> hd, tl
  in
  let argv = name :: path @ args in
  let value = ref None in
  let command =
    List.fold_right
      path
      ~f:(fun subcommand acc -> Command.group ~summary:"" [ subcommand, acc ])
      ~init:
        (Command.basic
           ~summary
           (let%map_open.Command x = param in
            fun () -> value := Some x))
  in
  Command_unix.run ~argv command;
  match !value with
  | None -> Error `Aborted_command_line_parsing__exit_code_already_printed
  | Some x -> Ok x
;;

let parse_command_line ?path ?(summary = default_command_name ^ " SUMMARY") param =
  stage (fun ?(on_error = ignore) ?(on_success = ignore) args ->
    let result = parse_command_line_raw ~path ~summary param args in
    match result with
    | Error `Aborted_command_line_parsing__exit_code_already_printed -> on_error ()
    | Ok x -> on_success x)
;;

module On_exec = struct
  type t =
    | Fail
    | Trust_me__I_understand_the_consequences_of_external_dependencies
  [@@deriving compare, sexp_of]

  let default = Fail
end

module Validate_command_line = struct
  let unit_anon = Command.Anons.map_anons ~f:ignore

  let filter_map_or_error_option xs ~f =
    List.map xs ~f |> Or_error.combine_errors |> Or_error.map ~f:List.filter_opt
  ;;

  let rec of_nested_anon : Command.Shape.Anons.Grammar.t -> _ = function
    | Ad_hoc s -> error_s [%message "Unable to check [Ad_hoc _] grammar." s]
    | Zero -> Ok None
    | One s -> Ok (Some (Command.Anons.( %: ) s (Command.Arg_type.create ignore)))
    | Many g ->
      let%bind.Or_error anon = of_nested_anon g in
      Ok (Option.map anon ~f:(Command.Anons.sequence >> unit_anon))
    | Maybe g ->
      let%bind.Or_error anon = of_nested_anon g in
      Ok (Option.map anon ~f:(Command.Anons.maybe >> unit_anon))
    | Concat gs ->
      let%bind.Or_error anons = filter_map_or_error_option gs ~f:of_nested_anon in
      Ok (List.reduce anons ~f:(fun a b -> unit_anon (Command.Anons.t2 a b)))
  ;;

  let require_grammar : Command.Shape.Anons.t -> _ = function
    | Usage s -> error_s [%message "Unable to check [Usage _]." s]
    | Grammar grammar -> Ok grammar
  ;;

  let param_of_anons anons =
    let%bind.Or_error grammar = require_grammar anons in
    let%bind.Or_error anon = of_nested_anon grammar in
    match anon with
    | None -> Ok (Command.Param.return ())
    | Some anon -> Ok (Command.Param.anon anon)
  ;;

  let param_of_user_flag flag_info ~flag_name =
    let%bind.Or_error num_occurrences = Command.Shape.Flag_info.num_occurrences flag_info
    and requires_arg = Command.Shape.Flag_info.requires_arg flag_info in
    let ({ aliases; doc; _ } : Command.Shape.Flag_info.t) = flag_info in
    let%bind.Or_error flag =
      let unit_flag = Command.Param.map_flag ~f:ignore in
      let make_flag f = Ok (unit_flag (f Command.Param.string)) in
      match requires_arg, num_occurrences with
      | true, { at_least_once = true; at_most_once = true } ->
        make_flag Command.Flag.required
      | true, { at_least_once = true; at_most_once = false } ->
        make_flag Command.Flag.one_or_more
      | true, { at_least_once = false; at_most_once = false } ->
        make_flag Command.Flag.listed
      | true, { at_least_once = false; at_most_once = true } ->
        make_flag Command.Flag.optional
      | false, { at_least_once = false; at_most_once = true } ->
        Ok (unit_flag Command.Flag.no_arg)
      | false, _ ->
        error_s
          [%message
            "Unexpected combination."
              (requires_arg : bool)
              (num_occurrences : Command.Shape.Num_occurrences.t)]
    in
    Ok (Command.Param.flag flag_name flag ~aliases ~doc)
  ;;

  let param_of_flag flag_info =
    match%bind.Or_error Command.Shape.Flag_info.flag_name flag_info with
    | "-help" | "-version" ->
      (* [Command.basic] will recreate these flags for us. It will raise if we try to
         create them manually. *)
      Ok None
    | flag_name ->
      let%bind.Or_error param = param_of_user_flag flag_info ~flag_name in
      Ok (Some param)
  ;;

  let unit_param = Command.Param.map ~f:ignore

  let param_of_flags flags =
    let%bind.Or_error params = filter_map_or_error_option flags ~f:param_of_flag in
    List.reduce params ~f:(fun a b -> unit_param (Command.Param.both a b))
    |> Option.value ~default:(Command.Param.return ())
    |> Or_error.return
  ;;

  let param_of_basic ({ summary; readme; anons; flags } : Command.Shape.Base_info.t) =
    let%bind.Or_error anons = param_of_anons anons
    and flags = param_of_flags flags in
    Ok
      (Command.basic
         ~summary
         ?readme:(Option.map readme ~f:const)
         (let%map_open.Command () = anons
          and () = flags in
          fun () -> ()))
  ;;

  let command_of_shape ?(on_exec = On_exec.default) (shape : Command.Shape.t) =
    let rec of_shape : Command.Shape.t -> _ = function
      | Basic base_info -> param_of_basic base_info
      | Exec (exec_info, get_shape) ->
        (match on_exec with
         | Trust_me__I_understand_the_consequences_of_external_dependencies ->
           of_shape (get_shape ())
         | Fail ->
           let s = "Got [Exec _] when [on_exec = Fail]" in
           error_s [%message s (exec_info : Command.Shape.Exec_info.t)])
      | Group group_info -> of_group group_info
      | Lazy shape -> of_shape (force shape)
    and of_group ({ summary; readme; subcommands } : _ Command.Shape.Group_info.t) =
      let%bind.Or_error subcommands =
        filter_map_or_error_option (force subcommands) ~f:(function
          | ("help" | "version"), _ ->
            (* [Command.group] will recreate these subcommands for us. It will raise if we
               try to create them manually. *)
            Ok None
          | name, user_subcommand ->
            let%bind.Or_error command = of_shape user_subcommand in
            Ok (Some (name, command)))
      in
      Ok (Command.group subcommands ~summary ?readme:(Option.map readme ~f:const))
    in
    of_shape shape
  ;;

  let f ?on_exec shape =
    let%bind.Or_error command = command_of_shape ?on_exec shape in
    Ok
      (fun args ->
         Or_error.try_with (fun () ->
           Command_unix.run command ~argv:(default_command_name :: args)))
  ;;
end

let validate_command_line = Validate_command_line.f

let with_env ~var ~value ~f =
  let prev = Sys.getenv var in
  Unix.putenv ~key:var ~data:value;
  Exn.protect ~f ~finally:(fun () ->
    match prev with
    | None -> Unix.unsetenv var
    | Some value -> Unix.putenv ~key:var ~data:value)
;;

let complete_command ?complete_subcommands ?which_arg cmd ~args =
  let which_arg =
    match which_arg with
    | Some n -> n + 1 (* to account for [argv[0]] *)
    | None -> List.length args
  in
  with_env ~var:"COMP_CWORD" ~value:(Int.to_string which_arg) ~f:(fun () ->
    Command_unix.run ?complete_subcommands ~argv:("__exe_name__" :: args) cmd)
;;

let complete ?which_arg param ~args =
  Command.Param.map param ~f:(fun (_ : _) () -> ())
  |> Command.basic ~summary:"SUMMARY"
  |> complete_command ?which_arg ~args
;;
