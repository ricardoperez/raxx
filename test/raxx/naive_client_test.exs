defmodule Raxx.NaiveClientTest do
  use ExUnit.Case
  # NOTE run for ever until shutdown

  alias Raxx.NaiveClient, as: Client

  test "Request with no body is sent to the server" do
    {port, listen_socket} = listen()

    request = Raxx.request(:GET, "http://localhost:#{port}/path?query")

    {:ok, _exchange} = Client.async(request)
    {:ok, socket} = accept(listen_socket)
    {:ok, first_request} = receive_packet(socket)

    # connection close is always added because the HTTP client does not support HTTP/1.1 pipelining
    assert "GET /path?query HTTP/1.1\r\nhost: localhost:#{port}\r\nconnection: close\r\n\r\n" ==
             first_request
  end

  test "Request with full body is sent to the server" do
    {port, listen_socket} = listen()

    request =
      Raxx.request(:POST, "http://localhost:#{port}/")
      |> Raxx.set_body("Hello, Raxx!!")
      |> Raxx.set_header("content-length", "13")

    {:ok, _exchange} = Client.async(request)
    {:ok, socket} = accept(listen_socket)
    {:ok, first_request} = receive_packet(socket)

    # connection close is always added because the HTTP client does not support HTTP/1.1 pipelining
    assert "POST / HTTP/1.1\r\nhost: localhost:#{port}\r\nconnection: close\r\ncontent-length: 13\r\n\r\nHello, Raxx!!" ==
             first_request
  end

  test "Request with content length and body raises an exception" do
    #
  end

  test "Request with chunked body raises an exception" do
    #
  end

  test "Response with no body is forwarded to client" do
    {port, listen_socket} = listen()

    request = Raxx.request(:GET, "http://localhost:#{port}/")

    {:ok, exchange} = Client.async(request)
    {:ok, socket} = accept(listen_socket)
    {:ok, _first_request} = receive_packet(socket)

    :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nfoo: bar\r\n\r\n")
    {:ok, response} = Client.yield(exchange, 1000)
    assert response.status == 200
    assert response.headers == [{"foo", "bar"}]
    assert response.body == ""
  end

  test "Response has full body when forwarded to the caller" do
    {port, listen_socket} = listen()

    request = Raxx.request(:GET, "http://localhost:#{port}/")

    {:ok, exchange} = Client.async(request)
    {:ok, socket} = accept(listen_socket)
    {:ok, _first_request} = receive_packet(socket)

    :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 13\r\n\r\nHello, Raxx!!")
    {:ok, response} = Client.yield(exchange, 1000)
    assert response.status == 200
    assert response.headers == [{"content-length", "13"}]
    assert response.body == "Hello, Raxx!!"
  end

  test "Response can be built from multiple packets" do
    packets = String.codepoints("HTTP/1.1 200 OK\r\ncontent-length: 13\r\n\r\nHello, Raxx!!")
    {port, listen_socket} = listen()

    request = Raxx.request(:GET, "http://localhost:#{port}/")

    {:ok, exchange} = Client.async(request)
    {:ok, socket} = accept(listen_socket)
    {:ok, _first_request} = receive_packet(socket)

    Enum.each(
      packets,
      fn packet ->
        :ok = :gen_tcp.send(socket, packet)
        Process.sleep(10)
      end
    )

    {:ok, response} = Client.yield(exchange, 1000)
    assert response.status == 200
    assert response.headers == [{"content-length", "13"}]
    assert response.body == "Hello, Raxx!!"
  end

  test "Response to a HEAD request has no body." do
    {port, listen_socket} = listen()

    request = Raxx.request(:HEAD, "http://localhost:#{port}/")

    {:ok, exchange} = Client.async(request)
    {:ok, socket} = accept(listen_socket)
    {:ok, _first_request} = receive_packet(socket)

    :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 13\r\n\r\n")
    {:ok, response} = Client.yield(exchange, 1000)
    assert response.status == 200
    assert response.headers == [{"content-length", "13"}]
    assert response.body == ""
  end

  defp listen(port \\ 0, transport \\ :tcp)

  defp listen(port, :tcp) do
    {:ok, listen_socket} = :gen_tcp.listen(port, mode: :binary, packet: :raw, active: false)
    {:ok, port} = :inet.port(listen_socket)
    {port, listen_socket}
  end

  defp listen(port, :ssl) do
    {:ok, listen_socket} =
      :ssl.listen(port,
        mode: :binary,
        active: false,
        certfile: test_certfile(),
        keyfile: test_keyfile()
      )

    {:ok, {_, port}} = :ssl.sockname(listen_socket)
    {port, listen_socket}
  end

  defp accept(listen_socket, transport \\ :tcp)

  defp accept(listen_socket, :tcp) do
    :gen_tcp.accept(listen_socket, 1_000)
  end

  defp accept(listen_socket, :ssl) do
    case :ssl.transport_accept(listen_socket) do
      {:ok, socket} ->
        case :ssl.handshake(socket) do
          {:ok, socket} ->
            {:ok, socket}

          {:error, :closed} ->
            {:error, :econnaborted}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp receive_packet(socket, transport \\ :tcp)

  defp receive_packet(socket, :tcp) do
    :gen_tcp.recv(socket, 0, 1_000)
  end

  defp receive_packet(socket, :ssl) do
    :ssl.recv(socket, 0, 1_000)
  end

  def test_certfile() do
    Path.expand("tls/cert.pem", __DIR__)
  end

  def test_keyfile() do
    Path.expand("tls/key.pem", __DIR__)
  end
end
