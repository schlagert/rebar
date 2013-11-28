%% -*- erlang-indent-level: 4;indent-tabs-mode: nil -*-
%% ex: ts=4 sw=4 et
%% -------------------------------------------------------------------
%%
%% rebar: Erlang Build Tools
%%
%% Copyright (c) 2011 Joe Williams (joe@joetify.com)
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.
%% -------------------------------------------------------------------

-module(rebar_upgrade).

-include("rebar.hrl").
-include_lib("kernel/include/file.hrl").

-export(['generate-upgrade'/2]).

%% for internal use only
-export([info/2]).

-define(TMP, "_tmp").

%% ====================================================================
%% Public API
%% ====================================================================

'generate-upgrade'(Config, ReltoolFile) ->
    {Cfg, ReltoolCfg} = rebar_rel_utils:load_config(Config, ReltoolFile),
    TargetParentDir = rebar_rel_utils:get_target_parent_dir(Cfg, ReltoolCfg),
    TargetDir = rebar_rel_utils:get_target_dir(Cfg, ReltoolCfg),
    PrevRelPath = rebar_rel_utils:get_previous_release_path(Cfg),
    OldVerPath = filename:join([TargetParentDir, PrevRelPath]),

    {Name, Ver} = rebar_rel_utils:get_reltool_release_info(ReltoolCfg),
    try
        {ok, ErtsChanged} = validate(TargetDir, OldVerPath, Name, Ver),
        {ok, InTar} = create(TargetDir, OldVerPath, Name, ErtsChanged),
        {ok, OutTar} = repackage(InTar, TargetDir, Name, Ver),
        ?CONSOLE("Successfully created upgrade package:~n  ~s~n", [OutTar])
    after
        cleanup(TargetDir, Name)
    end,
    {ok, Config}.

%% ===================================================================
%% Internal functions
%% ==================================================================

info(help, 'generate-upgrade') ->
    ?CONSOLE("Build an upgrade package.~n"
             "~n"
             "Valid command line options:~n"
             "  previous_release=path~n",
             []).

validate(TargetDir, OldVerPath, Name, Ver) ->
    true = rebar_utils:prop_check(
             filelib:is_dir(TargetDir),
             "Release directory doesn't exist yet, "
             "run 'rebar generate' first~n",
             []),
    true = rebar_utils:prop_check(
             filelib:is_dir(OldVerPath),
             "Previous release directory doesn't exist (~p)~n",
             [OldVerPath]),

    {NewName, NewVer, NewErtsVsn} =
        rebar_rel_utils:get_rel_release_info(Name, TargetDir),
    {OldName, OldVer, OldErtsVsn} =
        rebar_rel_utils:get_rel_release_info(Name, OldVerPath),

    true = rebar_utils:prop_check(
             NewName == OldName,
             "New and old .rel release names do not match~n",
             []),
    true = rebar_utils:prop_check(
             Name == NewName,
             "Reltool and .rel release names do not match~n",
             []),
    true = rebar_utils:prop_check(
             NewVer =/= OldVer,
             "New and old .rel contain the same version~n",
             []),
    true = rebar_utils:prop_check(
             Ver == NewVer,
             "Reltool and .rel versions do not match~n",
             []),
    {ok, NewErtsVsn =/= OldErtsVsn}.

create(TargetDir, OldVerPath, Name, ErtsChanged) ->
    Current = get_systools_release_name(TargetDir, Name),
    Previous = get_systools_release_name(OldVerPath, Name),
    Opts = get_systools_options(TargetDir, OldVerPath),
    ?DEBUG("systools:make_relup(\"~s\",[\"~s\"],[\"~s\"],~1024p)~n",
           [Current, Previous, Previous, Opts]),
    case systools:make_relup(Current, [Previous], [Previous], Opts) of
        {error, RelupMod, RelupError} ->
            ?CONSOLE("~s", [RelupMod:format_error(RelupError)]),
            ?ABORT("systools:make_relup/4 failed~n", []);
        {ok, _Relup, _RelupMod, []} ->
            ok;
        {ok, _Relup, RelupMod, RelupWarnings} ->
            ?CONSOLE("~s", [RelupMod:format_warning(RelupWarnings)]);
        _ ->
            ok
    end,
    ?DEBUG("systools:make_script(\"~s\",~1024p)~n", [Current, Opts]),
    case systools:make_script(Current, Opts) of
        {error, ScriptMod, ScriptError} ->
            ?CONSOLE("~s", [ScriptMod:format_error(ScriptError)]),
            ?ABORT("systools:make_script/2 failed~n", []);
        {ok, _ScriptMod, []} ->
            ok;
        {ok, ScriptMod, ScriptWarnings} ->
            ?CONSOLE("~s", [ScriptMod:format_warning(ScriptWarnings)]);
        _ ->
            ok
    end,
    TarOpts = case ErtsChanged of
                  true  -> [{erts, TargetDir} | Opts];
                  false -> Opts
              end,
    ?DEBUG("systools:make_tar(\"~s\",~1024p)~n", [Current, TarOpts]),
    case systools:make_tar(Current, TarOpts) of
        {error, TarMod, TarError} ->
            ?CONSOLE("~s", [TarMod:format_error(TarError)]),
            ?ABORT("systools:make_tar/2 failed~n", []);
        {ok, _TarMod, []} ->
            {ok, filename:join([TargetDir, Name ++ ".tar.gz"])};
        {ok, TarMod, TarWarnings} ->
            ?CONSOLE("~s", [TarMod:format_warning(TarWarnings)]),
            {ok, filename:join([TargetDir, Name ++ ".tar.gz"])};
        _ ->
            {ok, filename:join([TargetDir, Name ++ ".tar.gz"])}
    end.

repackage(SrcTar, SrcDir, Name, Ver) ->
    NameVer = Name ++ "_" ++ Ver,
    DestDir = filename:join([".", ?TMP]),
    ok = rebar_utils:ensure_dir(filename:join([DestDir, "dummy"])),
    ok = erl_tar:extract(SrcTar, [{cwd, DestDir}, compressed]),

    SrcBoot = filename:join([SrcDir, Name ++ ".boot"]),
    DestStartBoot = filename:join([DestDir, "releases", Ver, "start.boot"]),
    {ok, _} = file:copy(SrcBoot, DestStartBoot),

    DestNameBoot = filename:join([DestDir, "releases", Ver, Name ++ ".boot"]),
    {ok, _} = file:copy(SrcBoot, DestNameBoot),

    %% These are needed to find the clean .boot file (for escript) when the new
    %% release is permanent (active).
    SrcClean = filename:join([SrcDir, "releases", Ver, "start_clean.boot"]),
    DestClean = filename:join([DestDir, "releases", Ver, "start_clean.boot"]),
    {ok, _} = file:copy(SrcClean, DestClean),

    SrcRelup = filename:join([SrcDir, "relup"]),
    DestRelup = filename:join([DestDir, "releases", Ver, "relup"]),
    {ok, _} = file:copy(SrcRelup, DestRelup),

    SrcRel1 = filename:join([DestDir, "releases", Name ++ ".rel"]),
    DestRel1 = filename:join([DestDir, "releases", NameVer ++ ".rel"]),
    ok = rebar_file_utils:mv(SrcRel1, DestRel1),

    SrcRel2 = filename:join([DestDir, "releases", Ver, Name ++ ".rel"]),
    DestRel2 = filename:join([DestDir, "releases", Ver, NameVer ++ ".rel"]),
    ok = rebar_file_utils:mv(SrcRel2, DestRel2),

    SrcArgs = filename:join([SrcDir, "releases", Ver, "vm.args"]),
    DestArgs = filename:join([DestDir, "releases", Ver, "vm.args"]),
    {ok, _} = case filelib:is_regular(SrcArgs) of %% vm.args is optional
                  true ->
                      {ok, _} = file:copy(SrcArgs, DestArgs);
                  false ->
                      {ok, 0}
              end,

    {ok, Cwd} = file:get_cwd(),
    DestTar = filename:join([Cwd, NameVer ++ ".tar.gz"]),
    ok = file:set_cwd(DestDir),
    {ok, Tar} = erl_tar:open(DestTar, [write, compressed]),
    _ = [ok = erl_tar:add(Tar, filename:basename(Dir), [])
         || Dir <- filelib:wildcard(filename:join([".", "*"])),
            filelib:is_dir(Dir)],
    ok = erl_tar:close(Tar),
    ok = file:set_cwd(Cwd),
    {ok, DestTar}.

cleanup(TargetDir, Name) ->
    Paths =
        [
         filename:join([".", ?TMP]),
         filename:join([TargetDir, "relup"]),
         filename:join([TargetDir, "*.boot"]),
         filename:join([TargetDir, "*.script"]),
         filename:join([TargetDir, Name ++ ".tar.gz"])
        ],
    _ = [rebar_file_utils:rm_rf(Path) || Path <- Paths],
    ok.

get_systools_release_name(Path, Name) ->
    RelFile = rebar_rel_utils:get_rel_file_path(Name, Path),
    filename:join([filename:dirname(RelFile), Name]).

get_systools_options(TargetDir, OldVerPath) ->
    Paths = [filename:join([TargetDir, "lib", "*", "ebin"]),
             filename:join([OldVerPath, "lib", "*", "ebin"])],
    [silent, {path, Paths}, {outdir, TargetDir}].
