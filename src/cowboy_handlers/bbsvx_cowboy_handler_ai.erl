%%%-----------------------------------------------------------------------------
%%% BBSvx Cowboy AI Generation Handler
%%%-----------------------------------------------------------------------------

-module(bbsvx_cowboy_handler_ai).

-moduledoc "BBSvx Cowboy AI Code Generation Handler\n\n"
"Cowboy REST handler for AI-generated BabylonJS code.\n\n"
"Handles POST /ai/generate with {functor, argument} to generate 3D rendering code.".

-author("yan").

-include_lib("logjam/include/logjam.hrl").

-export([
    init/2,
    allowed_methods/2,
    content_types_accepted/2,
    malformed_request/2
]).
-export([accept_generate_request/2]).

%%%=============================================================================
%%% Cowboy REST Callbacks
%%%=============================================================================

init(Req0, State) ->
    Req1 = cowboy_req:set_resp_header(<<"Access-Control-Allow-Origin">>, <<"*">>, Req0),
    Req2 = cowboy_req:set_resp_header(<<"Access-Control-Allow-Methods">>, <<"POST, OPTIONS">>, Req1),
    Req3 = cowboy_req:set_resp_header(<<"Access-Control-Allow-Headers">>, <<"Content-Type">>, Req2),
    {cowboy_rest, Req3, State}.

allowed_methods(Req, State) ->
    {[<<"POST">>, <<"OPTIONS">>], Req, State}.

malformed_request(#{method := <<"POST">>} = Req, State) ->
    try
        {ok, Body, Req1} = cowboy_req:read_body(Req),
        DBody = jiffy:decode(Body, [return_maps]),

        case DBody of
            #{<<"functor">> := Functor, <<"namespace">> := Namespace} ->
                Argument = maps:get(<<"argument">>, DBody, <<"default">>),
                {false, Req1, State#{functor => Functor, argument => Argument, namespace => Namespace}};
            #{<<"functor">> := Functor} ->
                %% Default namespace
                Argument = maps:get(<<"argument">>, DBody, <<"default">>),
                {false, Req1, State#{functor => Functor, argument => Argument, namespace => <<"bbsvx:root">>}};
            _ ->
                Req2 = cowboy_req:set_resp_body(
                    jiffy:encode(#{error => <<"missing_functor">>}),
                    Req1
                ),
                {true, Req2, State}
        end
    catch
        _:_ ->
            Req3 = cowboy_req:set_resp_body(
                jiffy:encode(#{error => <<"invalid_json">>}),
                Req
            ),
            {true, Req3, State}
    end;
malformed_request(Req, State) ->
    {false, Req, State}.

content_types_accepted(Req, State) ->
    {[{{<<"application">>, <<"json">>, []}, accept_generate_request}], Req, State}.

%%%=============================================================================
%%% Request Handlers
%%%=============================================================================

accept_generate_request(Req0, #{functor := Functor, argument := Argument, namespace := Namespace} = State) ->
    ?'log-info'("AI Generation request for functor: ~p, argument: ~p, namespace: ~p", [Functor, Argument, Namespace]),

    %% Check local ETS cache first (prevents duplicate API calls during EPTO propagation)
    CacheTable = ensure_cache_table(),
    CacheKey = {Namespace, Functor},

    case ets:lookup(CacheTable, CacheKey) of
        [{CacheKey, CachedCode}] ->
            ?'log-info'("ETS cache hit for functor: ~p in namespace: ~p", [Functor, Namespace]),
            Response = #{code => CachedCode},
            Req1 = cowboy_req:set_resp_body(jiffy:encode(Response), Req0),
            {true, Req1, State};
        [] ->
            %% ETS cache miss - check if shape exists in ontology (received via EPTO)
            case lookup_shape_in_ontology(Namespace, Functor) of
                {ok, OntologyCode} ->
                    ?'log-info'("Ontology hit for functor: ~p (received via EPTO)", [Functor]),
                    %% Cache in ETS for faster subsequent lookups
                    ets:insert(CacheTable, {CacheKey, OntologyCode}),
                    Response = #{code => OntologyCode},
                    Req1 = cowboy_req:set_resp_body(jiffy:encode(Response), Req0),
                    {true, Req1, State};
                not_found ->
                    ?'log-info'("Cache miss for functor: ~p, calling Claude API", [Functor]),
                    case generate_babylonjs_code(Functor, Argument) of
                        {ok, Code} ->
                            %% Cache the result locally
                            ets:insert(CacheTable, {CacheKey, Code}),

                            %% Assert shape to ontology for distribution via EPTO
                            assert_shape_to_ontology(Namespace, Functor, Code),

                            Response = #{code => Code},
                            Req1 = cowboy_req:set_resp_body(jiffy:encode(Response), Req0),
                            {true, Req1, State};
                        {error, Reason} ->
                            ?'log-error'("AI generation failed: ~p", [Reason]),
                            ErrorResponse = #{
                                error => <<"generation_failed">>,
                                reason => format_error(Reason)
                            },
                            Req1 = cowboy_req:set_resp_body(jiffy:encode(ErrorResponse), Req0),
                            {false, Req1, State}
                    end
            end
    end.

%%%=============================================================================
%%% Internal Functions
%%%=============================================================================

%% Lookup shape in ontology using local_prove (no DB modifications)
%% May have been received via EPTO from another node
lookup_shape_in_ontology(Namespace, Functor) ->
    ?'log-info'("Looking up shape in ontology for functor: ~p using local_prove", [Functor]),
    try
        %% Get the prolog_state from the ontology actor
        case gen_statem:call({via, gproc, {n, l, {bbsvx_actor_ontology, Namespace}}}, get_prolog_state, 5000) of
            {ok, PrologState} ->
                %% Query: shape(FunctorAtom, Code) where Code is a variable
                %% In erlog, named variables are atoms wrapped in tuple: {'Code'}
                %% Convert binary functor to atom for Prolog matching
                FunctorAtom = binary_to_atom(Functor, utf8),
                Goal = {shape, FunctorAtom, {'Code'}},

                case bbsvx_erlog_db_local_prove:local_prove(Goal, PrologState) of
                    {succeed, Bindings} ->
                        %% Extract the Code value from bindings
                        case extract_binding('Code', Bindings) of
                            {ok, Code} when is_binary(Code) ->
                                ?'log-info'("Found shape for functor: ~p via local_prove", [Functor]),
                                %% Decode base64
                                DecodedCode = base64:decode(Code),
                                {ok, DecodedCode};
                            {ok, Code} when is_list(Code) ->
                                %% Might be a string (list of chars)
                                ?'log-info'("Found shape for functor: ~p (as string)", [Functor]),
                                CodeBin = list_to_binary(Code),
                                DecodedCode = base64:decode(CodeBin),
                                {ok, DecodedCode};
                            {ok, Other} ->
                                ?'log-info'("Shape code has unexpected type: ~p", [Other]),
                                not_found;
                            not_found ->
                                ?'log-info'("Code binding not found in result"),
                                not_found
                        end;
                    {fail} ->
                        ?'log-info'("No shape found for functor: ~p", [Functor]),
                        not_found
                end;
            {error, Reason} ->
                ?'log-info'("Failed to get prolog_state: ~p", [Reason]),
                not_found
        end
    catch
        exit:{timeout, _} ->
            ?'log-info'("Timeout getting ontology prolog_state"),
            not_found;
        exit:{noproc, _} ->
            ?'log-info'("Ontology actor not running for namespace: ~p", [Namespace]),
            not_found;
        _:Error ->
            ?'log-info'("Error looking up shape: ~p", [Error]),
            not_found
    end.

%% Extract a named variable's value from erlog bindings
%% Bindings is a map: #{VarName => {VarNum}, VarNum => Value, ...}
extract_binding(VarName, Bindings) when is_map(Bindings) ->
    case maps:get(VarName, Bindings, undefined) of
        {VarNum} when is_integer(VarNum) ->
            %% Follow the chain to get the actual value
            case maps:get(VarNum, Bindings, undefined) of
                undefined -> not_found;
                Value -> {ok, Value}
            end;
        undefined ->
            not_found;
        DirectValue ->
            %% Value was bound directly (shouldn't happen normally)
            {ok, DirectValue}
    end;
extract_binding(_VarName, _Bindings) ->
    not_found.

%% Unescape code retrieved from Prolog
unescape_from_prolog(Code) when is_binary(Code) ->
    %% Reverse escaping: \\n -> \n, \\" -> ", \\\\ -> \
    S1 = binary:replace(Code, <<"\\n">>, <<"\n">>, [global]),
    S2 = binary:replace(S1, <<"\\\"">>, <<"\"">>, [global]),
    S3 = binary:replace(S2, <<"\\\\">>, <<"\\">>, [global]),
    S3.

%% Assert shape fact to ontology for EPTO distribution
assert_shape_to_ontology(Namespace, Functor, Code) ->
    %% Base64 encode the code to avoid Prolog parsing issues with special chars
    EncodedCode = base64:encode(Code),

    %% Build the assertion goal: assertz(shape(functor, "base64_code")).
    Goal = iolist_to_binary([
        <<"assertz(shape(">>,
        Functor,
        <<", \"">>,
        EncodedCode,
        <<"\")). ">>
    ]),

    ?'log-info'("Asserting shape to ontology ~p: shape(~p, ...) [base64 encoded]", [Namespace, Functor]),

    case bbsvx_ont_service:prove(Namespace, Goal) of
        {ok, _TxId} ->
            ?'log-info'("Shape asserted successfully for functor: ~p", [Functor]),
            ok;
        {error, Reason} ->
            ?'log-error'("Failed to assert shape for ~p: ~p", [Functor, Reason]),
            {error, Reason}
    end.

%% Escape code string for embedding in Prolog
escape_for_prolog(Code) when is_binary(Code) ->
    %% Escape backslashes first, then quotes
    S1 = binary:replace(Code, <<"\\">>, <<"\\\\">>, [global]),
    S2 = binary:replace(S1, <<"\"">>, <<"\\\"">>, [global]),
    %% Escape newlines
    S3 = binary:replace(S2, <<"\n">>, <<"\\n">>, [global]),
    S3.

%% Ensure the cache table exists
ensure_cache_table() ->
    TableName = bbsvx_ai_code_cache,
    case ets:whereis(TableName) of
        undefined ->
            ets:new(TableName, [set, public, named_table, {read_concurrency, true}]);
        _Tid ->
            TableName
    end.

%% Generate BabylonJS code using configured AI provider
generate_babylonjs_code(Functor, Argument) ->
    Provider = application:get_env(bbsvx, ai_provider, claude),
    ?'log-info'("Using AI provider: ~p", [Provider]),
    case Provider of
        claude ->
            generate_with_claude(Functor, Argument);
        ollama ->
            generate_with_ollama(Functor, Argument);
        _ ->
            ?'log-warning'("Unknown AI provider ~p, falling back to Claude", [Provider]),
            generate_with_claude(Functor, Argument)
    end.

%% Generate code using Claude API
generate_with_claude(Functor, Argument) ->
    ApiKey = os:getenv("ANTHROPIC_API_KEY"),
    case ApiKey of
        false ->
            {error, missing_api_key};
        _ ->
            Prompt = build_prompt(Functor, Argument),
            call_claude_api(ApiKey, Prompt)
    end.

%% Generate code using Ollama (local)
generate_with_ollama(Functor, Argument) ->
    BaseUrl = application:get_env(bbsvx, ai_ollama_url, "http://localhost:11434"),
    Model = application:get_env(bbsvx, ai_ollama_model, "qwen2.5-coder:32b-instruct-q4_K_M"),
    Prompt = build_prompt(Functor, Argument),
    call_ollama_api(BaseUrl, Model, Prompt).

%% Build the prompt for Claude/Ollama
build_prompt(Functor, Argument) ->
    iolist_to_binary([
        <<"IMPORTANT: Your response will be directly executed as JavaScript code by eval(). ">>,
        <<"Do NOT include any explanations, comments outside the code, markdown formatting, or text before/after the function. ">>,
        <<"Output ONLY the raw JavaScript function - nothing else.\n\n">>,

        <<"Create a BabylonJS function for a 3D \"">>, Functor, <<"\" model.\n">>,
        <<"Instance name: \"">>, Argument, <<"\"\n\n">>,

        <<"REQUIREMENTS:\n">>,
        <<"1. Function signature: function create_">>, Functor, <<"(scene, position, instanceName) { ... return mesh; }\n">>,
        <<"2. NO imports - BabylonJS objects are globally available\n">>,
        <<"3. NO 'BABYLON.' prefix - use MeshBuilder, StandardMaterial, Color3, Vector3, Mesh directly\n">>,
        <<"4. Output ONLY the function - your entire response must be valid JavaScript\n\n">>,

        <<"MODELING GUIDELINES for \"">>, Functor, <<"\":\n">>,
        <<"- REALISTIC SCALE (1 unit = 1 meter): Use real-world sizes!\n">>,
        <<"  * Mouse/rat: ~0.05-0.1m tall\n">>,
        <<"  * Rabbit/cat: ~0.3-0.4m tall\n">>,
        <<"  * Dog/wolf: ~0.6-0.8m tall (at shoulder)\n">>,
        <<"  * Human/humanoid: ~1.7-1.9m tall\n">>,
        <<"  * Horse/cow: ~1.5-1.8m tall (at shoulder)\n">>,
        <<"  * Elephant: ~3-4m tall\n">>,
        <<"  * Dragon/giant: ~4-8m tall\n">>,
        <<"  * Small objects (cup, book): ~0.1-0.3m\n">>,
        <<"  * Furniture (chair, table): ~0.5-1m\n">>,
        <<"  * Buildings: ~3-10m+ tall\n">>,
        <<"- GROUND POSITIONING: The model's feet/base MUST rest on the ground (y=0).\n">>,
        <<"  Position all parts so the lowest point is at y=0, not centered at origin.\n">>,
        <<"  For a standing animal: legs bottom at y=0, body and head above.\n">>,
        <<"- Create an ANATOMICALLY RECOGNIZABLE model using multiple primitives\n">>,
        <<"- Use proper PROPORTIONS (e.g., for animals: head ~1/4 body size)\n">>,
        <<"- FACIAL FEATURES ARE MANDATORY for animals/creatures:\n">>,
        <<"  * EYES: Add 2 small black spheres positioned on the front of the head\n">>,
        <<"  * NOSE: Add a small sphere or box for the snout/nose\n">>,
        <<"  * Position eyes symmetrically on either side of the head's front\n">>,
        <<"- Add DEFINING FEATURES that make the entity identifiable:\n">>,
        <<"  * For animals: head, body, legs, tail, ears/horns, EYES, nose\n">>,
        <<"  * For objects: characteristic shapes and details\n">>,
        <<"- Position sub-meshes correctly relative to parent\n">>,
        <<"- Use Mesh.MergeMeshes() or parenting for complex shapes\n\n">>,

        <<"AVAILABLE PRIMITIVES:\n">>,
        <<"- MeshBuilder.CreateBox(name, {width, height, depth}, scene)\n">>,
        <<"- MeshBuilder.CreateSphere(name, {diameter, segments}, scene)\n">>,
        <<"- MeshBuilder.CreateCylinder(name, {height, diameterTop, diameterBottom}, scene)\n">>,
        <<"- MeshBuilder.CreateCapsule(name, {height, radius}, scene)\n">>,
        <<"- MeshBuilder.CreateTorus(name, {diameter, thickness}, scene)\n">>,
        <<"- MeshBuilder.CreateLathe(name, {shape, sideOrientation}, scene) for organic curves\n\n">>,

        <<"EXAMPLE - Lion (realistic size: ~1.2m shoulder height, ~2m body length):\n">>,
        <<"```\n">>,
        <<"function create_lion(scene, position, instanceName) {\n">>,
        <<"  const root = new Mesh('lion_' + instanceName, scene);\n">>,
        <<"  root.position = position;\n">>,
        <<"  // Real lion: ~1.2m at shoulder, ~2m body length\n">>,
        <<"  const bodyHeight = 0.5; // body radius\n">>,
        <<"  const shoulderHeight = 1.2; // meters from ground\n">>,
        <<"  const legHeight = shoulderHeight - bodyHeight;\n">>,
        <<"  \n">>,
        <<"  // Body - elongated capsule (~1.8m long)\n">>,
        <<"  const body = MeshBuilder.CreateCapsule('body', {height: 1.8, radius: bodyHeight}, scene);\n">>,
        <<"  body.rotation.z = Math.PI / 2;\n">>,
        <<"  body.position.y = shoulderHeight;\n">>,
        <<"  body.parent = root;\n">>,
        <<"  \n">>,
        <<"  // Head (~0.4m diameter)\n">>,
        <<"  const head = MeshBuilder.CreateSphere('head', {diameter: 0.4}, scene);\n">>,
        <<"  head.position = new Vector3(1.1, shoulderHeight + 0.1, 0);\n">>,
        <<"  head.parent = root;\n">>,
        <<"  \n">>,
        <<"  // Mane (~0.6m diameter)\n">>,
        <<"  const mane = MeshBuilder.CreateSphere('mane', {diameter: 0.6}, scene);\n">>,
        <<"  mane.position = new Vector3(0.9, shoulderHeight + 0.1, 0);\n">>,
        <<"  mane.parent = root;\n">>,
        <<"  \n">>,
        <<"  // 4 Legs - cylinders (legHeight tall, touching ground at y=0)\n">>,
        <<"  const legPositions = [[0.5, legHeight/2, 0.25], [0.5, legHeight/2, -0.25], [-0.5, legHeight/2, 0.25], [-0.5, legHeight/2, -0.25]];\n">>,
        <<"  legPositions.forEach((pos, i) => {\n">>,
        <<"    const leg = MeshBuilder.CreateCylinder('leg' + i, {height: legHeight, diameter: 0.12}, scene);\n">>,
        <<"    leg.position = new Vector3(...pos);\n">>,
        <<"    leg.parent = root;\n">>,
        <<"  });\n">>,
        <<"  \n">>,
        <<"  // Tail (~0.8m long)\n">>,
        <<"  const tail = MeshBuilder.CreateCylinder('tail', {height: 0.8, diameter: 0.05}, scene);\n">>,
        <<"  tail.position = new Vector3(-1.2, shoulderHeight - 0.2, 0);\n">>,
        <<"  tail.rotation.z = Math.PI / 4;\n">>,
        <<"  tail.parent = root;\n">>,
        <<"  \n">>,
        <<"  // Materials\n">>,
        <<"  const mat = new StandardMaterial('lionMat', scene);\n">>,
        <<"  mat.diffuseColor = new Color3(0.9, 0.7, 0.3);\n">>,
        <<"  [body, head, tail].concat(root.getChildren()).forEach(m => { if(m.material === null) m.material = mat; });\n">>,
        <<"  const maneMat = new StandardMaterial('maneMat', scene);\n">>,
        <<"  maneMat.diffuseColor = new Color3(0.6, 0.4, 0.1);\n">>,
        <<"  mane.material = maneMat;\n">>,
        <<"  return root;\n">>,
        <<"}\n">>,
        <<"```\n\n">>,

        <<"Now generate a similarly detailed model for \"">>, Functor, <<"\". Return ONLY the function code.">>
    ]).

%% Call Claude API
call_claude_api(ApiKey, Prompt) ->
    Url = "https://api.anthropic.com/v1/messages",
    Headers = [
        {"x-api-key", binary_to_list(iolist_to_binary(ApiKey))},
        {"anthropic-version", "2023-06-01"},
        {"content-type", "application/json"}
    ],

    RequestBody = jiffy:encode(#{
        model => <<"claude-opus-4-5-20251101">>,
        max_tokens => 8192,
        messages => [#{
            role => <<"user">>,
            content => Prompt
        }]
    }),

    HttpOptions = [
        {timeout, 90000},
        {connect_timeout, 10000}
    ],
    Options = [{body_format, binary}],

    ?'log-info'("Calling Claude API..."),

    case httpc:request(post, {Url, Headers, "application/json", RequestBody}, HttpOptions, Options) of
        {ok, {{_, 200, _}, _RespHeaders, ResponseBody}} ->
            ?'log-info'("Claude API response received"),
            parse_claude_response(ResponseBody);
        {ok, {{_, StatusCode, _}, _RespHeaders, ResponseBody}} ->
            ?'log-error'("Claude API error ~p: ~p", [StatusCode, ResponseBody]),
            {error, {http_error, StatusCode}};
        {error, Reason} ->
            ?'log-error'("HTTP request failed: ~p", [Reason]),
            {error, Reason}
    end.

%% Parse Claude API response and extract code
parse_claude_response(ResponseBody) ->
    try
        Response = jiffy:decode(ResponseBody, [return_maps]),
        Content = maps:get(<<"content">>, Response, []),

        %% Check stop_reason to detect truncation
        StopReason = maps:get(<<"stop_reason">>, Response, <<"unknown">>),
        Usage = maps:get(<<"usage">>, Response, #{}),
        OutputTokens = maps:get(<<"output_tokens">>, Usage, 0),
        ?'log-info'("Claude response - stop_reason: ~p, output_tokens: ~p", [StopReason, OutputTokens]),

        case StopReason of
            <<"max_tokens">> ->
                ?'log-warning'("Claude response was TRUNCATED (hit max_tokens limit). Output tokens: ~p", [OutputTokens]);
            <<"end_turn">> ->
                ?'log-info'("Claude response completed normally");
            Other ->
                ?'log-info'("Claude stop_reason: ~p", [Other])
        end,

        %% Extract text from content blocks
        Code = extract_code_from_content(Content),

        case Code of
            <<>> ->
                {error, no_code_generated};
            _ ->
                {ok, Code}
        end
    catch
        _:_ ->
            {error, invalid_response}
    end.

%% Extract code from Claude's content blocks
extract_code_from_content([]) ->
    <<>>;
extract_code_from_content([#{<<"type">> := <<"text">>, <<"text">> := Text} | _Rest]) ->
    %% Claude returns the function code in text blocks
    %% Strip any markdown code fences if present
    Cleaned = strip_markdown_fences(Text),
    Cleaned;
extract_code_from_content([_ | Rest]) ->
    extract_code_from_content(Rest).

%% Strip markdown code fences if present - trust Claude to return clean code
strip_markdown_fences(Text) ->
    Trimmed = string:trim(Text),
    %% Try multiple patterns to handle different fence formats
    %% Pattern 1: fences with newline before closing (standard)
    %% Pattern 2: fences without newline before closing
    %% Pattern 3: fences with optional whitespace
    case re:run(Trimmed, <<"```(?:javascript|js)?\\s*\\n(.+?)\\n?```\\s*$">>,
                [{capture, [1], binary}, dotall]) of
        {match, [CodeInFence]} ->
            string:trim(CodeInFence);
        nomatch ->
            %% Try without language specifier
            case re:run(Trimmed, <<"^```\\s*\\n?(.+?)\\n?```\\s*$">>,
                        [{capture, [1], binary}, dotall]) of
                {match, [CodeInFence2]} ->
                    string:trim(CodeInFence2);
                nomatch ->
                    %% No fences - use as-is
                    Trimmed
            end
    end.

%%%=============================================================================
%%% Ollama API Functions
%%%=============================================================================

%% Call Ollama API (OpenAI-compatible endpoint)
call_ollama_api(BaseUrl, Model, Prompt) ->
    Url = BaseUrl ++ "/v1/chat/completions",
    Headers = [
        {"content-type", "application/json"}
    ],

    RequestBody = jiffy:encode(#{
        model => list_to_binary(Model),
        messages => [#{
            role => <<"user">>,
            content => Prompt
        }],
        temperature => 0.5,  %% Lower temperature for more consistent code
        max_tokens => 4096   %% More tokens for detailed models
    }),

    HttpOptions = [
        {timeout, 120000},      %% Local models may be slower
        {connect_timeout, 5000}
    ],
    Options = [{body_format, binary}],

    ?'log-info'("Calling Ollama API at ~s with model ~s...", [Url, Model]),

    case httpc:request(post, {Url, Headers, "application/json", RequestBody}, HttpOptions, Options) of
        {ok, {{_, 200, _}, _RespHeaders, ResponseBody}} ->
            ?'log-info'("Ollama API response received"),
            parse_ollama_response(ResponseBody);
        {ok, {{_, StatusCode, _}, _RespHeaders, ResponseBody}} ->
            ?'log-error'("Ollama API error ~p: ~p", [StatusCode, ResponseBody]),
            %% Try to fall back to Claude if Ollama fails
            maybe_fallback_to_claude(StatusCode, Prompt);
        {error, {failed_connect, _}} ->
            ?'log-warning'("Ollama not available, falling back to Claude"),
            fallback_to_claude(Prompt);
        {error, Reason} ->
            ?'log-error'("Ollama HTTP request failed: ~p", [Reason]),
            {error, Reason}
    end.

%% Parse Ollama API response (OpenAI-compatible format)
parse_ollama_response(ResponseBody) ->
    try
        Response = jiffy:decode(ResponseBody, [return_maps]),
        Choices = maps:get(<<"choices">>, Response, []),

        case Choices of
            [#{<<"message">> := #{<<"content">> := Content}} | _] ->
                Code = strip_markdown_fences(Content),
                case Code of
                    <<>> -> {error, no_code_generated};
                    _ -> {ok, Code}
                end;
            _ ->
                {error, invalid_response}
        end
    catch
        _:_ ->
            {error, invalid_response}
    end.

%% Fallback to Claude if Ollama is unavailable
maybe_fallback_to_claude(StatusCode, _Prompt) when StatusCode >= 500 ->
    ?'log-warning'("Ollama server error, not falling back"),
    {error, {ollama_error, StatusCode}};
maybe_fallback_to_claude(_StatusCode, _Prompt) ->
    {error, ollama_error}.

fallback_to_claude(Prompt) ->
    ApiKey = os:getenv("ANTHROPIC_API_KEY"),
    case ApiKey of
        false ->
            ?'log-error'("Ollama unavailable and no ANTHROPIC_API_KEY set"),
            {error, no_ai_provider_available};
        _ ->
            ?'log-info'("Falling back to Claude API"),
            call_claude_api(ApiKey, Prompt)
    end.

%% Format error for JSON response
format_error(Reason) when is_atom(Reason) ->
    atom_to_binary(Reason);
format_error(Reason) when is_binary(Reason) ->
    Reason;
format_error(Reason) ->
    iolist_to_binary(io_lib:format("~p", [Reason])).
