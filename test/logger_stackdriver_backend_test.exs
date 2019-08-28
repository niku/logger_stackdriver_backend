defmodule LoggerStackdriverBackendTest do
  use ExUnit.Case
  doctest LoggerStackdriverBackend

  test "greets the world" do
    process =
      spawn(fn ->
        receive do
        after
          :infinity ->
            nil
        end
      end)

    expected = %GoogleApi.Logging.V2.Model.LogEntry{
      labels: %{
        application: "\":hello_world\"",
        module: "\"HelloWorld\"",
        pid: inspect(process)
      },
      logName: "projects/greeting/logs/my-first_log",
      resource: %GoogleApi.Logging.V2.Model.MonitoredResource{
        labels: %{project_id: "greeting"},
        type: "global"
      },
      severity: "INFO",
      sourceLocation: %GoogleApi.Logging.V2.Model.LogEntrySourceLocation{
        file: "lib/hello_world.ex",
        function: "hello/0",
        line: "18"
      },
      textPayload: "Hello world",
      timestamp: ~U[2019-08-29 01:00:05.879Z]
    }

    assert expected ==
             LoggerStackdriverBackend.build_entry(
               {:info, nil,
                {Logger, "Hello world", {{2019, 8, 29}, {1, 0, 5, 879}},
                 [
                   file: "lib/hello_world.ex",
                   function: "hello/0",
                   line: "18",
                   application: ":hello_world",
                   module: "HelloWorld",
                   pid: process
                 ]}},
               %LoggerStackdriverBackend{project_id: "greeting", log_name: "my-first_log"}
             )
  end
end
