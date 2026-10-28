# WardrikTesting

What a package built on [Wardrik's protocol](https://hexdocs.pm/wardrik_protocol) tests with: a
`Wardrik.Server` that runs Wardrik's operations as a script, so a package's tests need no Wardrik.
A package under the hub, like a channel or an HTTP surface, can't depend on the hub, even in its
tests; the hub's own suite tests them together, end to end.

## Install

```elixir
def deps do
  [
    {:wardrik_testing, "~> 0.1", only: :test}
  ]
end
```

## Test with it

Start the server under a name of the test's own, and act through a scope it runs:

```elixir
setup context do
  name = :"server #{context.test}"
  :ok = WardrikTesting.Server.start(name, secrets: ["wrk_good"], offered: [{"acme/triage", ["chat"]}])
  %{scope: Wardrik.Scope.new(WardrikTesting.Server, name, "acme/@maria", roles: [:owner], resources: ["*"])}
end

test "asks the agent", %{scope: scope} do
  {:ok, _message} = Wardrik.Agent.ask(scope, "acme/triage/t1", "Hi")
  assert_received {:asked, "acme/triage/t1", "Hi", "acme/@maria"}
end
```

The test is sent `{:ran, id, input}` for each operation, `{:streamed, id, input}` for each stream,
`{:asked, conversation, text, principal_id}` for each message, and `{:offered, worker, tools}` for
each worker's tools. An operation answers the protocol's own example, the agents `offered` are
listed and defined, and `acme/missing` is never found.

To have a message answered as a run is, in the conversation's log, start `WardrikEvents` under
`WardrikTesting.Server.events(name)`. A message saying `echo` waits on the call `call_1`, `fail`
fails, and any other is answered `Answered: ` and what it said. See `WardrikTesting.Script`.

An HTTP surface or a channel is given the server as `{WardrikTesting.Server, name}`, as the hub
gives itself.
