defmodule Raxx.Adapters.Ace.Handler do
  def init(conn, app) do
    partial = {:start_line, conn}
    buffer = ""
    # Need to keep track of conn for keep-alive, 4th spot might also be where to keep upgrade
    {:nosend, {app, partial, buffer}}
  end

  # If streaming response all new packets should be added to the buffer
  # States are
  # - basic (all new packets slowly build a request, dispatched as soon as ready)
  # - chunked (all new packets are buffered)
  # - streaming/websockets (new packets are streamed to some process)
  # - create an app protocol so that it can be called for many updates
  # %Basic{app: {mod, state}}
  # %Chunked{mod: mod}
  # Server.handle_request(app, request)
  # erlang deliveres messages in order so assume that info messages arrive in order.

  def handle_packet(packet, {app, partial, buffer}) do
    case process_buffer(buffer <> packet, partial) do
      {:more, partial, buffer} ->
        {:nosend, {app, partial, buffer}}
      {:ok, request, buffer} ->
        {mod, state} = app
        # call process_request function
        case mod.handle_request(request, state) do
          %{body: body, headers: headers, status: status_code} ->
            header_lines = Enum.map(headers, fn({x, y}) -> "#{x}: #{y}" end)
            raw = [
              Raxx.Response.status_line(status_code),
              Enum.join(header_lines, "\r\n"),
              "\r\n",
              "\r\n",
              body
            ]
            # Check keep alive status
            {:send, raw, {app, {:start_line, %{}}, ""}}
          upgrade = %Raxx.Chunked{} ->
            headers = upgrade.headers

            headers = if !List.keymember?(headers, "content-type", 0) do
              headers ++ [{"content-type", "text/plain"}]
            end || headers
            headers = headers ++ [{"transfer-encoding", "chunked"}]
            response = [
              Raxx.Response.status_line(200),
              Raxx.Response.header_lines(headers),
              "\r\n"
            ]
            # make sure next requests can keep coming in.
            # QUERY will a client keep sending request content if the response is chunked
            {:send, response, {upgrade, request, buffer}}
        end
    end
  end

  def handle_info(message, {%Raxx.Chunked{app: {mod, state}}, partial, buffer}) do
    case mod.handle_info(message, state) do
      {:chunk, data, state} ->
        {:send, Raxx.Chunked.to_packet(data), {%Raxx.Chunked{app: {mod, state}}, partial, buffer}}
      {:close, state} ->
        {:send, Raxx.Chunked.end_chunk, {%Raxx.Chunked{app: {mod, state}}, partial, buffer}}
    end
  end
  def terminate(_reason, {_app, _partial, _buffer}) do
    :ok
  end

  # Process part sould look like a function that you can pass to reduce

  def process_buffer(buffer, {:start_line, conn}) do
    case :erlang.decode_packet(:http_bin, buffer, []) do
      {:more, :undefined} ->
        {:more, {:start_line, conn}, buffer}
      {:ok, {:http_request, method, {:abs_path, path_string}, _version}, rest} ->
        %{path: path, query: query_string} = URI.parse(path_string)
        {:ok, query} = URI2.Query.decode(query_string || "")
        path = Raxx.Request.split_path(path)
        request = %Raxx.Request{method: method, path: path, query: query, headers: []}
        process_buffer(rest, {:headers, request})
    end
  end
  def process_buffer(buffer, {:headers, request = %{headers: headers}}) do
    case :erlang.decode_packet(:httph_bin, buffer, []) do
      {:more, :undefined} ->
        {:more, {:headers, request}, buffer}
      {:ok, {:http_header, _, key, _, value}, rest} ->
        process_buffer(rest, {:headers, add_header(request, key, value)})
      {:ok, :http_eoh, rest} ->
        process_buffer(rest, {:body, request})
    end
  end
  def process_buffer(buffer, {:body, request = %{headers: headers}}) do
    case :proplists.get_value("content-length", headers) do
      :undefined ->
        {:ok, request, buffer}
      raw ->
        length = :erlang.binary_to_integer(raw)
        case buffer do
          <<body :: binary-size(length)>> <> rest ->
            {:ok, %{request | body: body}, rest}
          _ ->
            {:more, {:body, request}, buffer}
        end
    end
  end

  # TODO case when adding key "Host" or "host"
  def add_header(request = %{headers: headers}, :Host, location) do
    [host, port] = case String.split(location, ":") do
      [host, port] -> [host, :erlang.binary_to_integer(port)]
      [host] -> [host, 80]
    end
    headers = headers ++ [{"host", location}]
    %{request | headers: headers, host: host, port: port}
  end
  def add_header(request = %{headers: headers}, key, value) do
    key = String.downcase("#{key}")
    headers = headers ++ [{key, value}]
    %{request | headers: headers}
  end
end
