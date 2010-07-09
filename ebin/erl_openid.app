{application, erl_openid, [
    {description,  "Erlang OpenId Library"},
    {vsn,          "0.1"},
    {registered, []},
    {modules,      [
        openid,
        openid_srv,
        openid_utils,
        yadis
    ]},
    {mod, {openid, []}},
    {applications, [kernel, stdlib, ssl]}
]}.
