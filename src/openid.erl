%%%-------------------------------------------------------------------
%%% File    : openid.erl
%%% Author  : Brendon Hogger <brendonh@dev.brendonh.org>
%%% Description :
%%%
%%% Created : 18 Sep 2009 by Brendon Hogger <brendonh@dev.brendonh.org>
%%%-------------------------------------------------------------------
-module(openid).

-export([
        start/2, stop/1, init/1, start_link/1,
        prepare/2, prepare/3, verify/3,
        discover/1, associate/1, authentication_url/3, test/0]).

-behaviour(application).
-behaviour(supervisor).

-include("openid.hrl").


%% ------------------------------------------------------------
%% Application
%% ------------------------------------------------------------

start(_, _) ->
         start_link([]).

stop(_) ->
        ok.


%% ------------------------------------------------------------
%% Main supervisor
%% ------------------------------------------------------------


start_link(Args) ->
                  supervisor:start_link({local, ?MODULE}, ?MODULE, Args).

init(_Args) ->
         {ok, {{one_for_one, 10, 10},
             [
                 {make_ref(),
                     {openid_srv, start_link, []},
                     permanent,
                     10000,
                     worker,
                     [openid_srv]
                 }
             ]
         }}.

%%
%% Intf to openid server
%%

prepare(UUID, Identifier) ->
    gen_server:call({global, openid_srv}, {prepare, UUID, Identifier}).

prepare(UUID, Identifier, Cache) ->
    gen_server:call({global, openid_srv}, {prepare, UUID, Identifier, Cache}).

verify(UUID, ReturnTo, Fields) ->
    gen_server:call({global, openid_srv}, {verify, UUID, ReturnTo, Fields}).

%% ------------------------------------------------------------
%% Discovery
%% ------------------------------------------------------------

discover(Identifier) ->
    Req = case yadis:retrieve(Identifier) of
              {none, Body} -> html_discovery(Body);
              #xrds{}=XRDS -> extract_authreq(XRDS);
              {error, Error} ->
                  %?DBG({error, Error}),
                  none
          end,

    case Req of
        #authReq{} -> set_identity_params(Req);
        _ -> Req
    end.


extract_authreq(XRDS) ->
    case authreq_by_opid(XRDS) of
        none -> authreq_by_claimed_id(XRDS);
        Req -> Req
    end.

authreq_by_opid(XRDS) ->
    authreq_by_opid(XRDS, ["http://specs.openid.net/auth/2.0/server",
                           "http://openid.net/server/1.1",
                           "http://openid.net/server/1.0"]).

authreq_by_opid(_, []) -> none;
authreq_by_opid(XRDS, [Type|Rest]) ->
    case find_service(XRDS#xrds.services, Type) of
        none -> authreq_by_opid(XRDS, Rest);
        Service -> build_authReq(XRDS, Service, {2,0})
    end.


find_service([], _) -> none;
find_service([#xrdService{uris=[]}|Rest], Type) -> find_service(Rest, Type);
find_service([#xrdService{types=Types}=Service|Rest], Type) ->
    case lists:any(fun(X) -> X == Type end, Types) of
        true -> Service;
        false -> find_service(Rest, Type)
    end.


authreq_by_claimed_id(XRDS) ->
    authreq_by_claimed_id(XRDS, [{"http://specs.openid.net/auth/2.0/signon", {2,0}},
                                 {"http://openid.net/signon/1.1", {1,1}},
                                 {"http://openid.net/signon/1.0", {1,0}}]).

authreq_by_claimed_id(_, []) ->
    none;
authreq_by_claimed_id(XRDS, [{Type,Version}|Rest]) ->
    case find_service(XRDS#xrds.services, Type) of
        none -> authreq_by_claimed_id(XRDS, Rest);
        Service -> build_authReq(XRDS, Service, Version)
    end.


build_authReq(XRDS, Service, Version) ->
    #authReq{opURLs=Service#xrdService.uris, 
             version=Version,
             claimedID=XRDS#xrds.claimedID,
             localID=Service#xrdService.localID}.


html_discovery(Body) ->
    html_discovery(Body, [{"openid2.provider", "openid2.local_id", {2,0}},
                          {"openid.server", "openid.delegate", {1,1}}]).

html_discovery(_, []) ->
    none;
html_discovery(Body, [{ProviderRel, LocalIDRel, Version}|Rest]) ->
    case openid_utils:get_tags(Body, "link", "rel", ProviderRel) of
        [Tag|_] ->
            case ?GVD("href", Tag, none) of
                none -> html_discovery(Body, Rest);
                URL ->
                    LocalID = html_local_id(Body, LocalIDRel),
                    #authReq{opURLs=[URL], version=Version, localID=LocalID}
            end;
        _ -> html_discovery(Body, Rest)
    end.

html_local_id(Body, RelName) ->
    case openid_utils:get_tags(Body, "link", "rel", RelName) of
        [Tag|_] -> ?GVD("href", Tag, none);
        _ -> none
    end.


set_identity_params(AuthReq) ->
    {Claimed, Local} = get_identity_params(AuthReq#authReq.claimedID,
                                           AuthReq#authReq.localID),
    AuthReq#authReq{claimedID=Claimed, localID=Local}.

get_identity_params(none, _) ->
    {"http://specs.openid.net/auth/2.0/identifier_select",
     "http://specs.openid.net/auth/2.0/identifier_select"};
get_identity_params(ClaimedID, none) ->
    {ClaimedID, ClaimedID};
get_identity_params(ClaimedID, LocalID) ->
    {ClaimedID, LocalID}.

%% ------------------------------------------------------------
%% Association
%% ------------------------------------------------------------

% Defaults from spec
-define(P, 1500073708273015748628013388693328252000303842391466352869527958572384115195772928792417592549921617769856041063651334172856114323013748155551037713908795501949688353681514443698908035718685336822727455568028009921661496375944512427).
-define(G, 2).

-define(CONTENT_TYPE, "application/x-www-form-urlencoded; charset=UTF-8").

associate(OpURL) ->
    application:start(crypto),

    MP = crypto:mpint(?P),
    MG = crypto:mpint(?G),

    {Public, Private} = crypto:dh_generate_key([MP,MG]),

    %?DBG({pub_priv, Public, Private, size(Public), size(Private)}),
    
    RollPub = roll(Public),
    %?DBG({rolled, RollPub, size(RollPub)}),

    Params = [{"openid.ns", "http://specs.openid.net/auth/2.0"},
              {"openid.mode", "associate"},
              {"openid.assoc_type", "HMAC-SHA1"},
              {"openid.session_type", "DH-SHA1"},
              {"openid.dh_modulus", base64:encode(roll(MP))},
              {"openid.dh_gen", base64:encode(roll(MG))},
              {"openid.dh_consumer_public", base64:encode(roll(Public))}],

    ReqBody = mochiweb_util:urlencode(Params),

    Request = {OpURL, [], ?CONTENT_TYPE, ReqBody},

    {ok, {_,_,Body}} = http:request(post, Request, [], []),

    Response = parse_keyvalue(Body),

    Handle = ?GV("assoc_handle", Response),
    ExpiresIn = list_to_integer(?GV("expires_in", Response)),
    
    ServPublic = unroll(base64:decode(?GV("dh_server_public", Response))),

    %?DBG({serv_pub, ServPublic}),

    EncMAC = base64:decode(?GV("enc_mac_key", Response)),

    ZZ = btwoc(crypto:dh_compute_key(ServPublic, Private, [MP,MG])),

    %?DBG({zz, ZZ}),

    MAC = crypto:exor(crypto:sha(ZZ), EncMAC),

    #assoc{handle=Handle, 
           created=now(), 
           expiresIn=ExpiresIn, 
           servPublic=ServPublic,
           mac=MAC}.

 
roll(N) when is_binary(N) ->
    <<_Size:32, Bin/binary>> = N,
    btwoc(Bin).

btwoc(<<X, _/binary>>=Bin) when X < 128 -> Bin;
btwoc(Bin) -> list_to_binary([<<0>>, Bin]).


unroll(Bin) when is_binary(Bin) ->
    Size = size(Bin),
    <<Size:32, Bin/binary>>.


parse_keyvalue(Body) ->
    lists:reverse(lists:foldl(
      fun(E, A) -> [split_kv(E, [])|A] end,
      [], string:tokens(Body, "\n"))).

split_kv([$:|Rest], Buff) -> {lists:reverse(Buff), Rest};
split_kv([C|Rest], Buff) -> split_kv(Rest, [C|Buff]).


%% ------------------------------------------------------------
%% Authentication
%% ------------------------------------------------------------

authentication_url(AuthReq, ReturnTo, Realm) ->
    
    Assoc = AuthReq#authReq.assoc,
    
    IDBits = case AuthReq#authReq.claimedID of
                 none -> [];
                 _ -> [{"openid.claimed_id", AuthReq#authReq.claimedID},
                       {"openid.identity", AuthReq#authReq.localID}]
             end,

    Params = [{"openid.ns", "http://specs.openid.net/auth/2.0"},
              {"openid.mode", "checkid_setup"},
              {"openid.assoc_handle", Assoc#assoc.handle},
              {"openid.return_to", ReturnTo},
              {"openid.realm", Realm}] ++ IDBits,
    
    QueryString = mochiweb_util:urlencode(Params),

    [URL|_] = AuthReq#authReq.opURLs,

    list_to_binary([URL, "?", QueryString]).

%% ------------------------------------------------------------
%% Tests
%% ------------------------------------------------------------

test() ->

    application:start(inets),
    application:start(ssl),

    Test = fun(ID) ->
                   ?DBG({identifier, ID}),
                   Req = discover(ID),
                   %?DBG({request, Req}),
                   [URL,_] = Req#authReq.opURLs,
                   Assoc = associate(URL),
                   ?DBG({assoc, Assoc}),
                   %?DBG({auth, authenticate(Req2, "http://dev.brendonh.org/return", "http://dev.brendonh.org/")}),
                   ok
           end,

    % 2.0
    Test("https://www.google.com/accounts/o8/id"),
    %Test("http://flickr.com/exbrend"),
    %Test("=brendonh"),

    % 1.0 / 1.1
    %?DBG({"AOL:", discover("http://openid.aol.com/brend")}),
    %?DBG({"Myspace:", discover("www.myspace.com")}),
    %?DBG({"LiveJournal:", discover("http://exbrend.livejournal.com")}),
    %?DBG({"PaulBonser:", discover("blog.paulbonser.com")}),

    application:stop(inets). % Avoid error spam from held-open connections




%% $ make test
%% erlc -o ebin -Wall -v +debug_info src/openid.erl
%% src/openid.erl:155: Warning: function unroll/1 is unused
%% erl +W w -pa ebin -noshell -pa ../mochiweb/ebin -s openid test -s init stop
%% <0.1.0>: {identifier,"https://www.google.com/accounts/o8/id"}
%% <0.1.0>: {request,{authReq,"https://www.google.com/accounts/o8/ud",
%%                            {2,0},
%%                            none,none}}
%% <0.1.0>: {assoc,{"46800",
%%                  "AO6d/PJErS+mEYxZNEsr3L/Tz6SvipjoQQW4TN8XxzHXTW8n4POIjk9kUBfl1yQvLF2rEmL4R3OqAKgDVsTIb9WzFF75+QmJXtXq5DqyQ4HRgBqgZk2RmijOHSKsVsZbsA==",
%%                  "CbImJ5wv7y1jgGCS3RWq5cCvByE="}}
%% <0.1.0>: {identifier,"http://flickr.com/exbrend"}
%% <0.1.0>: {request,{authReq,"https://open.login.yahooapis.com/openid/op/auth",
%%                            {2,0},
%%                            none,none}}
%% <0.1.0>: {assoc,{"14400",
%%                  "EBXqqs44y4MkuvOIVGF+TSUot+/FGqBtMZJm8KyQXwabUc09iB2AesfVb4J2iM2JaPdvk0VgfYur7ywJY9zCZA5bvSNKEOicFP5SAVBsfdCNyCUEjMRt0tvcDAnygWzo",
%%                  "wBens28gyUh8NzNKVS3IafvWeYE="}}
%% <0.1.0>: {identifier,"=brendonh"}
%% <0.1.0>: {request,{authReq,"https://authn.fullxri.com/authentication/",
%%                            {2,0},
%%                            "=brendonh",none}}
%% <0.1.0>: {assoc,{"1800",
%%                  "AKngKTyiIQ0JcX3/vXrnavfyLWCj6hsiOTYypoKPS25DAaprDRKkq5gXL4q0Foc+YAUqrLlTuT63W6PeVSpZEornRfNHs3Trfoxggp3N4uE8BFvlHvyf1XySXNANPbLLFQ==",
%%                  "KIW/+jlgDASt3Xx8T7vHfb1F0vU="}}
