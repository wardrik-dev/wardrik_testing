defmodule WardrikTesting.Script do
  @moduledoc """
  How `WardrikTesting.Server` answers a message: as a run does, written into the conversation's log
  in the server's `WardrikTesting.Server.events/1`, where the test started them.

    * A message saying `echo` waits on the call `call_1`, to `echo` with `%{"text" => "hi"}`.
    * A message saying `fail` fails, as `It broke.`
    * Any other is answered `Answered: ` and what it said.

  Deciding the call answers `Done.`, by whoever the scope is, where it may decide the call; anyone
  else is refused. A denial without a reason is `Rejected.`, as the hub's is. Cancelling stops the run.
  """

  alias Wardrik.Error
  alias Wardrik.Scope
  alias WardrikTesting.Server

  @doc "Answers the message `input` gives, as `agent.ask` does."
  @spec ask(Scope.t(), map()) :: {:ok, map()}
  def ask(%Scope{wardrik: name} = scope, %{"agent" => conversation, "content" => text} = input) do
    Server.tell(name, {:asked, conversation, text, scope.principal.id})
    message = input["id"] || "m-#{System.unique_integer([:positive])}"
    sender = %{"id" => scope.principal.id}

    write(scope, conversation, "message.created", %{
      "message" => %{"id" => message, "role" => "user"},
      "sender" => sender
    })

    write(scope, conversation, "run.started", %{
      "run" => %{"id" => "r1", "message_ids" => [message]}
    })

    turn(scope, conversation, text)
    {:ok, %{"message" => %{"id" => message, "cursor" => "c"}}}
  end

  @doc "Decides the call `input` names, as `agent.approve` and `agent.deny` do."
  @spec decide(Scope.t(), String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def decide(scope, id, %{"agent" => conversation} = input) do
    if decides?(scope, conversation),
      do: decided(scope, id, input),
      else: {:error, Error.new(:forbidden, "You may not decide this.")}
  end

  @doc "Stops the run `input` names, as `agent.cancel` does."
  @spec cancel(Scope.t(), map()) :: {:ok, nil}
  def cancel(%Scope{wardrik: name} = scope, %{"agent" => conversation}) do
    Server.hold(name, conversation, {"idle", []})
    write(scope, conversation, "run.cancelled", %{"run" => %{"id" => "r1"}})
    {:ok, nil}
  end

  defp decided(
         %Scope{wardrik: name} = scope,
         id,
         %{"agent" => conversation, "interrupt" => call} = input
       ) do
    decision = if id == "agent.approve", do: "approved", else: "rejected"
    by = %{"id" => scope.principal.id, "name" => scope.principal.attributes[:name]}
    resolved = %{"interrupt" => %{"id" => call}, "decision" => decision, "resolved_by" => by}

    write(
      scope,
      conversation,
      "interrupt.resolved",
      Map.merge(resolved, said(id, input))
    )

    Server.hold(name, conversation, {"idle", []})
    answered(scope, conversation, "Done.")
    {:ok, %{"decisions" => [%{"id" => call, "decision" => decision}]}}
  end

  defp said("agent.deny", input), do: %{"reason" => input["reason"] || "Rejected."}
  defp said(_approve, input), do: Map.take(input, ["note"])

  defp decides?(%Scope{grants: grants}, conversation) do
    {:ok, resource} = Wardrik.Resource.agent(conversation)
    Enum.any?(grants, &decides_on?(&1, resource))
  end

  defp decides_on?(%Wardrik.Statement{actions: actions, resources: resources}, resource),
    do:
      Enum.any?(actions, &(&1 in ["*", "agent.decide"])) and
        Enum.any?(resources, &WardrikEvents.Pattern.covers?(&1, resource))

  defp turn(%Scope{wardrik: name} = scope, conversation, "echo" <> _rest) do
    call = %{"id" => "call_1", "name" => "echo", "arguments" => %{"text" => "hi"}}

    interrupt = %{
      "id" => "call_1",
      "tool_call_id" => "call_1",
      "reason" => "tool_approval",
      "name" => "echo",
      "message" => "Run echo?"
    }

    write(scope, conversation, "tool_call.started", %{
      "tool" => %{"name" => "echo", "call" => call},
      "decided" => %{"by" => "policy"}
    })

    Server.hold(name, conversation, {"parked", [interrupt]})

    write(scope, conversation, "run.interrupted", %{
      "run" => %{"id" => "r1"},
      "interrupts" => [interrupt]
    })
  end

  defp turn(scope, conversation, "fail" <> _rest) do
    error = %{"type" => "internal", "message" => "It broke."}
    write(scope, conversation, "run.failed", %{"run" => %{"id" => "r1"}, "error" => error})
  end

  defp turn(scope, conversation, text), do: answered(scope, conversation, "Answered: " <> text)

  defp answered(scope, conversation, text) do
    messages = [%{"role" => "assistant", "parts" => [%{"type" => "text", "content" => text}]}]

    write(scope, conversation, "run.completed", %{
      "run" => %{"id" => "r1"},
      "messages" => messages
    })
  end

  defp write(%Scope{wardrik: name}, conversation, type, data) do
    events = Server.events(name)

    if Process.whereis(events),
      do: :ok = WardrikEvents.append(events, conversation, {type, "runs/r1", data}),
      else: :ok
  end
end
