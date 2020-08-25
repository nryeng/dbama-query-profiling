# Query Profiling in MySQL (DBAMA, June 2020)

These are the notes for
[my presentation/demo](https://www.youtube.com/watch?v=hKGWdqlEt98) at
https://dbama.now.sh/, on 2020-06-30. All SQL in this repo is licensed
as CC0, so feel free to copy, share and use as you please.

MySQL has a large toolbox for query analysis:

1. [`EXPLAIN`](https://dev.mysql.com/doc/refman/8.0/en/explain.html) to
   show plans (try `EXPLAIN FORMAT=TREE`!)
2. [`EXPLAIN
   ANALYZE`](https://mysqlserverteam.com/mysql-explain-analyze/) to show
   the execution profile
3. [Optimizer
   tracing](https://dev.mysql.com/doc/internals/en/optimizer-tracing.html)
   to inspect the choices the optimizer makes
4. [`performance_schema`](https://dev.mysql.com/doc/refman/8.0/en/performance-schema.html)
   to show too many details about too many things ;-)
5. [Optimizer
   hints](https://dev.mysql.com/doc/refman/8.0/en/optimizer-hints.html) to
   prevent/fix bad plans
6. [`optimizer_switch`](https://dev.mysql.com/doc/refman/8.0/en/switchable-optimizations.html)
   to prevent specific optimizations in a connection

This presentation covers 2 and some small portion of 4.

## Execution profiling

We can profile the query execution using `EXPLAIN ANALYZE`.

MySQL uses the Volcano iterator model for query execution. Each iterator
is a subtype of
[RowIterator](https://dev.mysql.com/doc/dev/mysql-server/latest/classRowIterator.html). When
run with `EXPLAIN ANALYZE`, each iterator is wrapped in a
[TimingIterator](https://dev.mysql.com/doc/dev/mysql-server/latest/classTimingIterator.html)
that records timestamps and counts in order to generate the profile at
the end of execution.

We're using the [test_db](https://github.com/datacharmer/test_db)
dataset to demonstrate.

```
EXPLAIN FORMAT=TREE
SELECT *
FROM
  EMPLOYEES AS e
  JOIN current_dept_emp AS de
    ON e.emp_no=de.emp_no
  JOIN departments d
    ON de.dept_no=d.dept_no
;
```

```
EXPLAIN ANALYZE
SELECT *
FROM
  EMPLOYEES AS e
  JOIN current_dept_emp AS de
    ON e.emp_no=de.emp_no
  JOIN departments d
    ON de.dept_no=d.dept_no
;
```

## Memory profiling

Note: This is an experiment. I've never done this before!

We're going to do memory usage profiling by running a query in one
connection and monitoring it with performance_schema (and logging to a
table) from another connection.


### Starting the server

I had to do a few tweaks to my MySQL Server setup:

The server needs to be able to do SELECT ... INTO OUTFILE, so set the
`--secure-file-priv` option accordingly.

The default history length for
performance_schema.events_stages_history_long is too low to record the
history of my example, so I increased it:
`--performance_schema_events_stages_history_long_size=1000000`. The
correct value is system/load specific. This worked for me in my demo
setup. YMMV.


### A simple connection to monitor

We're going to need the connection ID of this connection:

```
SELECT CONNECTION_ID();
```

The simplest query we can easily monitor:

```
SELECT SLEEP(300); -- in seconds, use fractions if you want to
```

In order to have something more interesting to look at, we're using
[ST_Buffer](https://dev.mysql.com/doc/refman/8.0/en/spatial-operator-functions.html#function_st-buffer)
and
[ST_Buffer_Strategy](https://dev.mysql.com/doc/refman/8.0/en/spatial-operator-functions.html#function_st-buffer-strategy).

Why ST_Buffer? Because I know that function, and I know its memory
allocation pattern. And we can easily adjust how much memory we want it
to use.

This query will first generate a small polygon, then larger and larger
polygons, until the largest one with 50000 points (each point is two
doubles (=16 bytes), plus overhead). We're sprinkling out some
[SLEEP](https://dev.mysql.com/doc/refman/8.0/en/miscellaneous-functions.html#function_sleep)
calls, too, so that it will execute slow enough for us to monitor.

```
SELECT
  i,
  SLEEP(2),
  ST_Buffer(POINT(0,0), 1000, ST_Buffer_Strategy('point_circle', i))
FROM (VALUES ROW(1), ROW(10), ROW(100), ROW(1000), ROW(10000), ROW(50000) ORDER BY 1) AS ints (i);
```


### A monitoring connection

We're going to do our monitoring from another connection than the one
running the query (it's busy!).

First, we need to find the thread ID of the connection running our
interesting query, which is not the same as the connection ID. We can
find connection IDs like we did above, or using `SHOW PROCESSLIST`. But
that doesn't give us the thread ID that performance_schema uses. The
mapping between connection ID and thread ID is in
`performance_schema.threads`:

```
SET @pid = 8; -- Replace with value you got above
```

```
SELECT * FROM performance_schema.threads WHERE PROCESSLIST_ID=@pid\G
```

```
SET @tid = (SELECT THREAD_ID FROM performance_schema.threads WHERE PROCESSLIST_ID=@pid);
```

Now we can inspect the other fields of the `threads` table. The
`PROCESSLIST_COMMAND` field is useful:

```
SELECT PROCESSLIST_COMMAND FROM performance_schema.threads WHERE THREAD_ID=@tid;
```

Try it both while the monitored connection is running a query and between
queries. We can use this to detect when a connection is starting to
execute a query and use that to trigger our monitoring, and to stop it
once the query finishes.

See [`monitor_connection.sql`](./monitor_connection.sql).

```
CALL monitor_connection(@pid);
```

### Analyzing the collected data

The stored procedure creates two tables, `monitoring_data` and
`monitoring_stages`. These table contain all memory statistics gathered
and the start and end timestamp of all query processing stage changes,
respectively.

We're only going to look at one specific type of memory allocation,
those used to store geometries. We're also summing up the total memory
used.

```
SET @min_ts = (SELECT UNIX_TIMESTAMP(MIN(TS)) FROM monitoring_data);
(SELECT 'wall_clock', 'relative time', 'geom', CAST('total' AS CHAR))
UNION
(SELECT
   TS AS the_ts,
   UNIX_TIMESTAMP(TS) - @min_ts,
   (SELECT CURRENT_NUMBER_OF_BYTES_USED FROM monitoring_data WHERE EVENT_NAME='memory/sql/Geometry::ptr_and_wkb_data' AND TS=the_ts),
   SUM(CURRENT_NUMBER_OF_BYTES_USED)
 FROM monitoring_data
 GROUP BY the_ts
)
INTO OUTFILE '~/demo/memory.csv'
  FIELDS TERMINATED BY ','
  OPTIONALLY ENCLOSED BY '"'
;
```
