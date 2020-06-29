DROP PROCEDURE IF EXISTS monitor_connection;
DELIMITER $$
CREATE PROCEDURE monitor_connection(
  IN conn_id BIGINT UNSIGNED
)
BEGIN
  DECLARE thd_id BIGINT UNSIGNED; -- P_S thread ID of connection conn_id
  DECLARE state VARCHAR(16); -- Current connection state
  DECLARE stage_ignore_before BIGINT UNSIGNED; -- Ignore history before this timestamp
  DECLARE stage_min_ts BIGINT UNSIGNED; -- Earliest timestamp in stage history
  
  # Thread ID is used as key in P_S, so get the thread ID of the suppliced connection ID.
  SET thd_id = (SELECT THREAD_ID FROM performance_schema.threads WHERE PROCESSLIST_ID=conn_id);
  
  # Get the current maximum stage history table timestamp. All new events will have a more recent timestamp.
  SET stage_ignore_before = (SELECT MAX(TIMER_END) FROM performance_schema.events_stages_history_long WHERE THREAD_ID=thd_id);

  # Create a table to log memory uage data.
  DROP TABLE IF EXISTS monitoring_data;
  CREATE TABLE monitoring_data AS
    SELECT
      NOW(6) AS 'TS',
      THREAD_ID,
      EVENT_NAME,
      COUNT_ALLOC,
      COUNT_FREE,
      SUM_NUMBER_OF_BYTES_ALLOC,
      SUM_NUMBER_OF_BYTES_FREE,
      LOW_COUNT_USED,
      CURRENT_COUNT_USED,
      HIGH_COUNT_USED,
      LOW_NUMBER_OF_BYTES_USED,
      CURRENT_NUMBER_OF_BYTES_USED,
      HIGH_NUMBER_OF_BYTES_USED
    FROM performance_schema.memory_summary_by_thread_by_event_name
    WHERE THREAD_ID = thd_id;

  SELECT CONCAT ('Waiting for connection ', conn_id, ' (thread ', thd_id, ') to start executing a query') AS 'Status';

  # Wait for query to start.
  REPEAT
    SET state = (SELECT PROCESSLIST_COMMAND FROM performance_schema.threads WHERE THREAD_ID=thd_id);
  UNTIL state = 'Query' END REPEAT;

  SELECT 'Connection monitoring starting' AS 'Status';

  # Repeat until query finishes.
  REPEAT
    SET state = (SELECT PROCESSLIST_COMMAND FROM performance_schema.threads WHERE THREAD_ID=thd_id);
    INSERT INTO monitoring_data
      SELECT
        NOW(6) AS 'TS',
        THREAD_ID,
        EVENT_NAME,
        COUNT_ALLOC,
        COUNT_FREE,
        SUM_NUMBER_OF_BYTES_ALLOC,
        SUM_NUMBER_OF_BYTES_FREE,
        LOW_COUNT_USED,
        CURRENT_COUNT_USED,
        HIGH_COUNT_USED,
        LOW_NUMBER_OF_BYTES_USED,
        CURRENT_NUMBER_OF_BYTES_USED,
        HIGH_NUMBER_OF_BYTES_USED
      FROM performance_schema.memory_summary_by_thread_by_event_name
      WHERE THREAD_ID = thd_id
	;
    DO SLEEP(0.1);
  UNTIL state = 'Sleep' END REPEAT;
  
  SELECT 'Connection monitoring ended' AS 'Status';
  
  # Get the minimum timestamp in query stage history.
  
  SET stage_min_ts = (SELECT MIN(timer_start) FROM performance_schema.events_stages_history_long WHERE THREAD_ID=thd_id AND timer_start > stage_ignore_before);
  SELECT stage_min_ts AS 'stage_min_ts', stage_ignore_before AS 'stage_ignore_before';
  # Timestamps in picoseconds, divide by 10^12.
  SELECT
    EVENT_NAME,
    SOURCE,
    timer_start,
    timer_end,
    (timer_start - stage_min_ts) / 1000000000000 AS start,
    (timer_end - stage_min_ts) / 1000000000000 AS end
    FROM performance_schema.events_stages_history_long
    WHERE THREAD_ID = thd_id AND timer_start > stage_ignore_before
    ORDER BY timer_start;
  # Dump it to a table, too:
  DROP TABLE IF EXISTS monitoring_stages;
  CREATE TABLE monitoring_stages AS
    SELECT
      EVENT_NAME,
      SOURCE,
      timer_start,
      timer_end,
      (timer_start - stage_min_ts) / 1000000000000 AS start,
      (timer_end - stage_min_ts) / 1000000000000 AS end
      FROM performance_schema.events_stages_history_long
      WHERE THREAD_ID = thd_id AND timer_start > stage_ignore_before
      ORDER BY timer_start
  ;
END $$
DELIMITER ;
