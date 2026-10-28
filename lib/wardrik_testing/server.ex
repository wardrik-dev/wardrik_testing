defmodule WardrikTesting.Server do
  @moduledoc """
  A `Wardrik.Server` for a test, under a name of the test's own, that runs Wardrik's operations as
  a script, so a package built on the protocol tests without a Wardrik.

      setup do
        :ok = WardrikTesting.Server.start(:my_test, secrets: ["wrk_good"])
        %{scope: Wardrik.Scope.new(WardrikTesting.Server, :my_test, "acme/@maria")}
      end

  The test is sent what the server is asked: `{:ran, id, input}` for each operation,
  `{:streamed, id, input}` for each stream, `{:asked, conversation, text, principal_id}` for each
  message, and `{:offered, worker, tools}` for each worker's tools.

  An operation answers the protocol's own example of what it gives, or nothing. An agent the test
  names as `acme/missing`, or any conversation of it, isn't found. The agents the test `offered` are listed and defined with
  the channels it gave each, and a conversation waits on a person, or doesn't, as its turns left
  it. A message is answered as `WardrikTesting.Script` says, written into the conversation's log
  where the test started `events/1`. See `start/2`.
  """

  @behaviour Wardrik.Server

  alias Wardrik.Error
  alias Wardrik.Scope
  alias WardrikTesting.Script

  @event %{
    "specversion" => "1.0",
    "id" => "1",
    "source" => "wardrik://test/agents/acme/triage",
    "type" => "wardrik.run.completed",
    "time" => "2026-10-28T12:00:00Z",
    "data" => %{"run" => %{"id" => "r1"}, "messages" => []}
  }

  @doc """
  Starts the server for the calling test under `name`, which the test is registered as. Takes
  `:secrets`, the API tokens it knows, each acting for `acme/@maria` as an owner, and `:offered`,
  the agents it offers, each as `{id, channels}` or `{id, channels, description}`.
  """
  @spec start(atom(), keyword()) :: :ok
  def start(name, opts \\ []) do
    opts = Keyword.validate!(opts, secrets: [], offered: [])
    state = state_name(name)
    initial = fn -> %{secrets: MapSet.new(opts[:secrets]), offered: opts[:offered], held: %{}} end

    ExUnit.Callbacks.start_supervised!(%{
      id: state,
      start: {Agent, :start_link, [initial, [name: state]]}
    })

    Process.register(self(), name)
    :ok
  end

  @doc "Returns the name of the `WardrikEvents` the server writes a turn into, for the test to start."
  @spec events(atom()) :: atom()
  def events(name), do: Module.concat(name, Events)

  @doc "Stops `secret` working."
  @spec revoke(atom(), String.t()) :: :ok
  def revoke(name, secret), do: update(name, &%{&1 | secrets: MapSet.delete(&1.secrets, secret)})

  @doc "Offers the agent `id` too, answering in `channels`, described as `description` where given."
  @spec add_agent(atom(), String.t(), [String.t()], String.t() | nil) :: :ok
  def add_agent(name, id, channels, description \\ nil),
    do: update(name, &%{&1 | offered: &1.offered ++ [{id, channels, description}]})

  @doc "Offers `offered` in place of what the server offered, each as `{id, channels}`."
  @spec offer_agents(atom(), [{String.t(), [String.t()]}]) :: :ok
  def offer_agents(name, offered), do: update(name, &%{&1 | offered: offered})

  @doc false
  @spec hold(atom(), String.t(), {String.t(), [map()]}) :: :ok
  def hold(name, conversation, held),
    do: update(name, &%{&1 | held: Map.put(&1.held, conversation, held)})

  @doc false
  @spec tell(atom(), term()) :: :ok
  def tell(name, message) do
    with pid when is_pid(pid) <- Process.whereis(name), do: send(pid, message)
    :ok
  end

  @impl Wardrik.Server
  def authenticate(name, secret) do
    case MapSet.member?(state(name).secrets, secret) do
      true -> {:ok, Scope.new(__MODULE__, name, "acme/@maria", roles: [:owner], resources: ["*"])}
      false -> {:error, Error.new(:unauthorized, "That isn't a token here.")}
    end
  end

  @impl Wardrik.Server
  def run(%Scope{wardrik: name} = scope, id, input) do
    tell(name, {:ran, id, input})
    answer(scope, id, input)
  end

  @impl Wardrik.Server
  def stream(%Scope{wardrik: name}, id, %{"after" => "nope"} = input) do
    tell(name, {:streamed, id, input})
    {:error, Error.new(:invalid_request, "That cursor doesn't read.")}
  end

  def stream(%Scope{wardrik: name}, id, input) do
    tell(name, {:streamed, id, input})
    {:ok, Stream.concat([{@event, "cursor-1"}], Stream.repeatedly(&quiet/0))}
  end

  @impl Wardrik.Server
  def follow(_scope, "acme/broken", _input, _opts), do: [{:text, "Half"}, {:failed, :boom}]

  def follow(_scope, "acme/waiting", _input, _opts),
    do: [{:waiting, [%Wardrik.Interrupt{id: "call_1", reason: :tool_approval}]}]

  def follow(_scope, _agent, input, _opts),
    do: [
      {:text, "Re: "},
      {:text, input},
      {:done, %Wardrik.Reply{message: "m1", run: "r1", text: "Re: " <> input}}
    ]

  @impl Wardrik.Server
  def offer(%Scope{wardrik: name}, tools) do
    tell(name, {:offered, self(), tools})
    :ok
  end

  @impl Wardrik.Server
  def answer({caller, ref}, message) do
    send(caller, {ref, message})
    :ok
  end

  defp answer(_scope, _id, %{"agent" => "acme/missing" <> _rest = agent}),
    do: {:error, Error.new(:not_found, "There's no agent #{agent}.")}

  defp answer(%Scope{wardrik: name}, "agents.list", _input) do
    agents =
      for offered <- state(name).offered,
          id = elem(offered, 0),
          do: %{"id" => id, "name" => Path.basename(id)}

    {:ok, %{"agents" => agents}}
  end

  defp answer(%Scope{wardrik: name}, "agent.definition", %{"agent" => agent}),
    do: name |> state() |> Map.fetch!(:offered) |> List.keyfind(agent, 0) |> defined(agent)

  defp answer(%Scope{wardrik: name}, "agent.read", %{"agent" => conversation}) do
    {status, interrupts} = Map.get(state(name).held, conversation, {"idle", []})
    agent = %{"id" => conversation, "name" => Path.basename(conversation)}
    {:ok, %{"agent" => agent, "status" => status, "pending" => 0, "interrupts" => interrupts}}
  end

  defp answer(scope, "agent.ask", input), do: Script.ask(scope, input)

  defp answer(scope, id, input) when id in ["agent.approve", "agent.deny"],
    do: Script.decide(scope, id, input)

  defp answer(scope, "agent.cancel", input), do: Script.cancel(scope, input)

  defp answer(_scope, id, _input) do
    case WardrikProtocol.operation(id).output do
      %{"examples" => [example | _rest]} -> {:ok, example}
      _none -> {:ok, nil}
    end
  end

  defp defined({agent, channels}, agent), do: defined({agent, channels, nil}, agent)

  defp defined({agent, channels, description}, agent) do
    described = description || "Answers #{agent}."
    definition = %{"model" => "m", "channels" => channels, "description" => described}
    {:ok, %{"definition" => definition, "missing" => []}}
  end

  defp defined(nil, agent), do: {:error, Error.new(:not_found, "There's no agent #{agent}.")}

  defp quiet do
    receive do
      :never -> :never
    end
  end

  defp state(name), do: Agent.get(state_name(name), & &1)
  defp update(name, change), do: Agent.update(state_name(name), change)
  defp state_name(name), do: Module.concat(name, WardrikTesting)
end
