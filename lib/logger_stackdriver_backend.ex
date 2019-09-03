defmodule LoggerStackdriverBackend do
  @moduledoc false

  @behaviour :gen_event

  # Log severity level mapping between elixir's logger and Stackdriver
  # https://hexdocs.pm/logger/1.9.1/Logger.html#module-levels
  # https://cloud.google.com/logging/docs/reference/v2/rest/v2/LogEntry#logseverity
  @log_severity %{
    debug: "DEBUG",
    info: "INFO",
    warn: "WARNING",
    error: "ERROR"
  }

  # 10 seconds
  @default_interval 10_000

  defstruct buffer: [],
            interval: nil,
            timer_ref: nil,
            project_id: nil,
            log_name: nil

  def build_entry(
        {level, _group_leader,
         {Logger, message, {{year, month, day}, {hour, minute, second, millisecond}}, metadata}},
        %__MODULE__{project_id: project_id, log_name: log_name}
      ) do
    log_name_for_entry = "projects/#{project_id}/logs/#{log_name}"

    # https://cloud.google.com/logging/docs/api/v2/resource-list#resource-types
    monitored_resource = %GoogleApi.Logging.V2.Model.MonitoredResource{
      type: "global",
      labels: %{project_id: project_id}
    }

    # It assumes the given timestamp represents as UTC.
    timestamp =
      NaiveDateTime.from_erl!(
        {{year, month, day}, {hour, minute, second}},
        {millisecond * 1000, 3}
      )
      |> DateTime.from_naive!("Etc/UTC")

    severity = @log_severity[level]

    # source location from metadata
    # https://hexdocs.pm/logger/1.9.1/Logger.html#module-metadata
    {file, metadata} = Keyword.pop(metadata, :file)
    {line, metadata} = Keyword.pop(metadata, :line)
    {function, metadata} = Keyword.pop(metadata, :function)

    # Additionaly, use request_id in metadata as insert_id on Stackdriver
    # https://cloud.google.com/logging/docs/reference/v2/rpc/google.logging.v2#google.logging.v2.LogEntry
    #
    # This is often used by plug and/or phoenixframework.
    # https://hexdocs.pm/plug/1.8.3/Plug.RequestId.html
    {insert_id, metadata} = insert_id = Keyword.pop(metadata, :request_id)

    # store rest of metadata as labels
    labels = for {k, v} <- metadata, do: {k, inspect(v)}, into: Map.new()

    log_entry_source_location =
      if file || line || function do
        %GoogleApi.Logging.V2.Model.LogEntrySourceLocation{
          file: file,
          line: line,
          function: function
        }
      end

    # The type of a message is chardata which may be represented by list.
    # https://github.com/elixir-lang/elixir/blob/v1.9.1/lib/logger/lib/logger.ex#L390
    # To send to stackdriver, it needs to convert to string.
    text_payload = IO.chardata_to_string(message)

    %GoogleApi.Logging.V2.Model.LogEntry{
      insertId: insert_id,
      logName: log_name_for_entry,
      resource: monitored_resource,
      timestamp: timestamp,
      severity: severity,
      labels: labels,
      textPayload: text_payload,
      sourceLocation: log_entry_source_location
    }
  end

  @impl :gen_event
  def init(__MODULE__) do
    config = Application.get_env(:logger, :logger_stackdriver_backend)
    interval = Keyword.get(config, :interval, @default_interval)
    project_id = Keyword.get(config, :project_id)
    log_name = Keyword.get(config, :log_name)

    if is_binary(project_id) and project_id !== "" and
         is_binary(log_name) and log_name !== "" and
         is_integer(interval) and 0 < interval do
      timer_ref = Process.send_after(self(), :tick, interval)

      {:ok,
       %__MODULE__{
         interval: interval,
         timer_ref: timer_ref,
         project_id: project_id,
         log_name: log_name
       }}
    else
      {:error, :ignore}
    end
  end

  @impl :gen_event
  def handle_call({:configure, _options}, %__MODULE__{} = state) do
    # TODO
    {:ok, :ok, state}
  end

  @impl :gen_event
  def handle_event(event, state)

  # https://hexdocs.pm/logger/1.9.1/Logger.html#module-custom-backends
  # It is recommended that handlers ignore messages
  # where the group leader is in a different node than the one where the handler is installed.
  def handle_event({_, group_leader, {Logger, _, _, _}}, %__MODULE__{} = state)
      when node(group_leader) != node() do
    {:ok, state}
  end

  def handle_event({_, _, {Logger, _, _, _}} = event, %__MODULE__{buffer: buffer} = state) do
    {:ok, %{state | buffer: [build_entry(event, state) | buffer]}}
  end

  def handle_event(:flush, %__MODULE__{buffer: []} = state) do
    {:ok, state}
  end

  def handle_event(:flush, %__MODULE__{buffer: buffer} = state) do
    request = %GoogleApi.Logging.V2.Model.WriteLogEntriesRequest{entries: buffer}

    {:ok, %{token: token}} = Goth.Token.for_scope("https://www.googleapis.com/auth/logging.write")
    conn = GoogleApi.Logging.V2.Connection.new(token)

    GoogleApi.Logging.V2.Api.Entries.logging_entries_write(conn, body: request)

    {:ok, %{state | buffer: []}}
  end

  @impl :gen_event
  def handle_info(:tick, %__MODULE__{} = state) do
    timer_ref = Process.send_after(self(), :tick, state.interval)
    :gen_event.notify(self(), :flush)
    {:ok, %{state | timer_ref: timer_ref}}
  end

  # It needs to work with :console backend
  # I'm not sure why ;/
  def handle_info({:io_reply, _, :ok}, state) do
    {:ok, state}
  end
end
