# Diode Server
# Copyright 2021 Diode
# Licensed under the Diode License, Version 1.1
defmodule Network.RpcWs do
  @behaviour :cowboy_websocket_handler

  def init(req, state) do
    {:cowboy_websocket, req, state}
  end

  def websocket_init(state) do
    PubSub.subscribe(:rpc)
    {:ok, state}
  end

  def websocket_handle({:ping, message}, state) do
    {:reply, {:pong, message}, state}
  end

  def websocket_handle({:binary, message}, state) do
    websocket_handle({:text, message}, state)
  end

  def websocket_handle({:text, message}, state) do
    with {:ok, message} <- Poison.decode(message) do
      {_status, response} = Network.Rpc.handle_jsonrpc(message, extra: {__MODULE__, :execute_rpc})
      {:reply, {:text, Poison.encode!(response)}, state}
    else
      {:ok, state} ->
        {:ok, state}

      _ ->
        {:reply, {:text, Poison.encode!("what?")}, state}
    end
  end

  def execute_rpc(method, params) do
    case method do
      "eth_subscribe" ->
        case params do
          ["newHeads", %{"includeTransactions" => includeTransactions}] ->
            subscribe({:block, includeTransactions})

          ["newHeads" | _] ->
            :ok
            subscribe({:block, false})

          ["syncing"] ->
            subscribe(:syncing)
        end

      "eth_unsubscribe" ->
        [id] = params

        ret =
          case Process.delete({:subs, id}) do
            nil -> false
            _ -> true
          end

        {ret, 200, nil}

      _ ->
        nil
    end
  end

  defp subscribe(what) do
    id = Base16.encode(Random.uint63h(), false)
    Process.put({:subs, id}, what)

    # Netowrk.Rpc.result() format
    {id, 200, nil}
  end

  def websocket_terminate(_terminate_reason, _arg1, _state) do
    :ok
  end

  def websocket_info(any, state) do
    case any do
      {:rpc, :block, block} ->
        reply =
          Enum.filter(Process.get(), fn
            {{:subs, _id}, {:block, _includeTransactions}} -> true
            _ -> false
          end)
          |> Enum.map(fn {{:subs, id}, {:block, includeTransactions}} ->
            {block, _, _} =
              Network.Rpc.execute_rpc("eth_getBlockByNumber", [block, includeTransactions], [])

            {:text,
             Poison.encode!(%{
               "jsonrpc" => "2.0",
               "method" => "eth_subscription",
               "params" => %{
                 "subscription" => id,
                 "result" => Json.prepare!(block)
               }
             })}
          end)

        if reply != [] do
          {:reply, reply, state}
        else
          {:ok, state}
        end

      {:rpc, :syncing, bool} ->
        reply =
          Enum.filter(Process.get(), fn
            {{:subs, _id}, :syncing} -> true
            _ -> false
          end)
          |> Enum.map(fn {{:subs, id}, _} ->
            {:text,
             Poison.encode!(%{
               "jsonrpc" => "2.0",
               "method" => "eth_subscription",
               "params" => %{
                 "subscription" => id,
                 "result" => %{
                   "syncing" => bool,
                   "status" => %{
                     "startingBlock" => Chain.peak(),
                     "currentBlock" => Chain.peak(),
                     "highestBlock" => Chain.peak(),
                     "pulledStates" => 0,
                     "knownStates" => 0
                   }
                 }
               }
             })}
          end)

        if reply != [] do
          {:reply, reply, state}
        else
          {:ok, state}
        end

      _ ->
        :io.format("rpc_ws:websocket_info(~p)~n", [any])
        {:ok, state}
    end
  end
end
