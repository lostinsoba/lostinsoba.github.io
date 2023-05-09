---
title: "Distributed locks: SQL"
date: 2023-05-09T23:31:40+06:00
summary: "Distributed locks using SQL based RDBMS"
tags: ["postgres", "mysql"]
---

# SQL

This post contains information about locking techniques using native mechanisms provided by SQL RDBMS  
Chosen dialect is PostgreSQL, but mentioned snippets can be easily adopted to other management systems

| Lock type        | API interface                                                                          |
|------------------|----------------------------------------------------------------------------------------|
| Mutex            | `Acquire(taskID string) (bool, error)` <br> `Release(taskID string) (bool, error)`     |
| Timeout          | `Acquire(taskID string) (bool error)`                                                  |
| State transition | `SetStatus(taskID string, status int) error` <br> `Capture(limit int) ([]Task, error)` |

## Locks

### Mutex

In this case we only have 2 states:
- acquired
- released

so in our example we're going to use a special boolean field to acquire the lock:

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

Changing the mutex state:

```sql
-- $1 = true (acquire)
-- $1 = false (release)

update task_state set acquired = $1 where id = 'task_a' and acquired != $1;
-- UPDATE 1 (lock acquired, only one of the clients will receive this)

update task_state set acquired = $1 where id = 'task_a' and acquired != $1;
-- UPDATE 0 (lock already acquired by previous request)
```

> Since it's not guaranteed that client will be able to release the lock, this approach is more suitable for cases when it's necessary to cancel next task processing if previous attempt did not succeed 

### Timeout

To implement this type of lock we need to store 2 variables: 
- timestamp (unix epoch)
- timeout (duration, same units as timestamp)

```sql
create table task (
  id       text   not null,
  ts       bigint not null, -- time we acquired the lock
  timeout  bigint not null  -- time interval lock will remain exclusive for client
);
-- CREATE TABLE

alter table task add constraint task_unique_id unique (id);
-- ALTER TABLE

insert into task (id, ts, timeout) values ('daily_task_a', 1445412480, 86400);
-- INSERT 0 1

insert into task (id, ts, timeout) values ('daily_task_b', 1445412480, 86400);
-- INSERT 0 1

insert into task (id, ts, timeout) values ('hourly_task_a', 1445412480, 3600);
-- INSERT 0 1
```

It doesn't require client to release the lock this time, lock will simply be re-acquired when passed `ts` value is higher than sum of stored `ts` and `timeout`:

```sql
-- $1 = current timestamp

update task set ts = $1 where id = 'hourly_task_a' and ts + timeout < $1;
-- UPDATE 1
```

### State transition

This approach is quite similar to the previous one, but now we are going to use:
- current task status (instead of timestamp)
- list of task statuses we can use to start processing a task

For example, consider having the following statuses:
- done (also initial status)
- in_progress (client exclusive)
- failed

```sql
-- task_status will be used as an atomic int
create type task_status as enum ('done', 'in_progress', 'failed');
-- task stores atomic with corresponding task identifier
create table task (
  id     text        not null,
  status task_status not null
);

insert into task (id, status) values ('task_a', 'done');
-- INSERT 0 1

insert into task (id, status) values ('task_b', 'done');
-- INSERT 0 1
```

so we can lock any of `done` and `failed` by using `in_progress`:

```sql
update task set status = 'in_progress'
where id in (
  select id
  from task
  where status = any(array ['done', 'failed'])
  limit 3
) returning id, status

--    id   |   status
-----------+-------------
--  task_a | in_progress
--  task_b | in_progress
-- (1 row)
-- UPDATE 1
```

and release the lock by setting `failed` or `done`:

```sql
update task set status = $1 where id = 'task_a';
-- UPDATE 1
```

We can also add status `timeout` but there are two limitations:

1. along with `failed` it's not guaranteed that client will be able to set this state  
so it takes to set the timeout value for every task and launch another worker that will be setting the correct task statuses on specified interval
2. it's also possible to compute status `timeout` (instead of storing it in database) inside read operations  
but that can lead to problems related with cases when API and database return different statuses

## Extensions

### Retries

In addition to already existing condition required to acquire the lock, we could also add a number of retries left:

```sql
-- $1 = retries_left for already existing tasks

alter table task add column retries_left integer not null default 0;
update task set retries_left = $1;
```

and to the `Acquire/Capture` interface:

```sql
update task set ..., retries_left = retries_left - 1 where ... and retries_left != 0
```

so every time we acquire the lock this value will be decremented until it reach the zero

### Queues

As it was mentioned earlier (in State transition) we could also acquire multiple locks, but within any other type of lock:

```sql
update task set ...
where id in (
  select id
  from task
  where ... and queue_id = $1
  limit 3
) returning id, status
```

this can be achieved with adding new field to the table:

```sql
-- $1 = queue for already existing tasks

alter table task add column queue_id text not null default 'default';
update task set queue_id = $1;
```

and/or changing the existing unique index for task ids if you want to make them unique inside queues:

```sql
alter table task drop constraint task_unique_id;
alter table task add constraint queue_task_unique_id unique (queue_id, id);
```

what will also require to rewrite the `Acquire` query to make it differ between similar ids across different queues
