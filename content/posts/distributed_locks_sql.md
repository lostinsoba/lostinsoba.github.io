---
title: "Distributed locks: SQL"
date: 2023-02-26T20:58:09+06:00
summary: "Distributed locks using SQL based RDBMS"
tags: ["postgres", "mysql"]
---

# SQL

> Description

Basically, it's just any update operation that returns the number of rows affected

## Mutex

In this case we have only 2 states (acquired/released), so in our example we're going to use a special boolean field to acquire the lock:

```sql
create table task_state (
  id       text    not null, -- required, must be unique
  acquired boolean not null  -- <- mutex
);
-- CREATE TABLE

alter table task_state add constraint task_state_unique_id unique (id);
-- ALTER TABLE

insert into task_state (id, acquired) values ('task_a', false);
-- INSERT 0 1

insert into task_state (id, acquired) values ('task_b', false);
-- INSERT 0 1

insert into task_state (id, acquired) values ('task_c', false);
-- INSERT 0 1
```

#### Change the mutex state

```sql
-- $1 = true (acquire)
-- $1 = false (release)

update task_state set acquired = $1 where id = 'task_a' and acquired != $1;
-- UPDATE 1

update task_state set acquired = $1 where id = 'task_a' and acquired != $1;
-- UPDATE 0
```

## Task queue

This case demonstrates a simple API for capturing tasks from different queues:

### With external schedule

```sql
create table task_state (
  id       text    not null,
  queue_id text    not null, -- <- will be used in conditional statement
  acquired boolean not null
);
-- CREATE TABLE

alter table task_state add constraint task_unique_id unique (id);
-- ALTER TABLE

insert into task_state (id, queue_id, acquired) values ('task_a', 'queue_a', false);
-- INSERT 0 1

insert into task_state (id, queue_id, acquired) values ('task_b', 'queue_a', false);
-- INSERT 0 1

insert into task_state (id, queue_id, acquired) values ('task_c', 'queue_b', false);
-- INSERT 0 1
```

#### Change queued task states

```sql
-- $1 = true (acquire)
-- $1 = false (release)

update task_state set acquired = $1
where id in (
  select id
  from task_state
  where queue_id = any(array ['queue_a']) and acquired != $1
  limit 3
) returning id;

--   id    
----------
-- task_a
-- task_b
-- (2 rows)
-- UPDATE 2

update task_state set acquired = $1
where id in (
  select id
  from task_state
  where queue_id = any(array ['queue_a']) and acquired != $1
  limit 3
) returning id;

-- (0 rows)
-- UPDATE 0
```

### With internal schedule

```sql
create table task_state (
  id       text    not null,
  queue_id text    not null,
  ts       bigint  not null -- <- task execution timestamp (next_ts, last_ts)
);
-- CREATE TABLE

alter table task_state add constraint task_unique_id unique (id);
-- ALTER TABLE

insert into task_state (id, queue_id, ts) values ('task_a', 'daily', 1445412480);
-- INSERT 0 1

insert into task_state (id, queue_id, ts) values ('task_b', 'daily', 1445412480);
-- INSERT 0 1

insert into task_state (id, queue_id, ts) values ('task_c', 'hourly', 1445412480);
-- INSERT 0 1
```

#### Capture task by setting next timestamp

This approach requires a worker to have knowledge about how frequently tasks should be executed and calculate:

- current timestamp
- next execution timestamp (`next_ts` + duration, durations like (24, 48..) hours are more suitable)

and perform the following query by some specified interval (ex. every hour)

```sql
-- $1 = next execution timestamp
-- $2 = current timestamp

update task_state set next_ts = $1
where id in (
  select id
  from task_state
  where queue_id = 'daily' and next_ts > $2
  limit 3
) returning id;

--   id   |  next_ts     
----------+------------
-- task_a | 1445412540
-- task_b | 1445412540
-- (2 rows)
-- UPDATE 2
```

#### Capture task by checking previous timestamp

Otherwise, we can simply check if the required amount of time has passed

```sql
-- $1 = current timestamp
-- $2 = current timestamp - duration

update task_state set last_ts = $1
where id in (
  select id
  from task_state
  where queue_id = 'hourly' and last_ts < $2
  limit 3
) returning id;

--   id    
----------
-- task_c
-- (1 row)
-- UPDATE 1
```

## State transition

This approach provides API that is more flexible for customizations:

```sql
-- task_status will be used as an atomic int
create type task_status as enum ('idle', 'in_progress', 'failed', 'done');
-- task stores atomic with corresponding task identifier
create table task (
  id     text        not null,
  status task_status not null
);

insert into task (id, status) values ('task_a', 'idle');
-- INSERT 0 1

insert into task (id, status) values ('task_b', 'done');
-- INSERT 0 1
```

#### Change task status by ID

```sql
-- $1 = required task status

update task set status = $1
where id = 'task_a' and status != $1;

-- UPDATE 1
```

#### Capture batch of available tasks
```sql
update task set status = 'in_progress'
where id in (
  select id
  from task
  where status = any(array ['idle', 'failed'])
  limit 3
) returning id, status

--    id   |   status
-----------+-------------
--  task_a | in_progress
-- (1 row)
-- UPDATE 1
```

