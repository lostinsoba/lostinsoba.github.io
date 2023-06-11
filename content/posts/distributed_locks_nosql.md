---
title: "Distributed locks: NoSQL"
date: 2023-06-12T02:27:21+06:00
summary: "Distributed locks using NoSQL based DBMS"
tags: ["redis"]
---

This post contains information about locking techniques using native mechanisms provided by NoSQL DBMS
Chosen dialect is Redis, but following snippets can be easily adopted to other management systems

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

```redis
-- only adds new elements if not exists (arg: nx)
-- $mutex_value = 0 (released)
-- $mutex_value = 1 (acquired)

zadd task nx $mutex_value task_id
-- (integer) 1 // created
-- (integer) 0 // already exists
```

Changing the mutex state:

```redis
-- only modifies existing elements (arg: xx)
-- returns number of elements changed (arg: ch)

zadd task xx ch $mutex_value task_id
-- (integer) 1 // lock acquired, only one of the clients will receive this

zadd task xx ch $mutex_value task_id
-- (integer) 0 // lock already acquired by previous request
```

> Since it's not guaranteed that client will be able to release the lock, this approach is more suitable for cases when it's necessary to cancel next task processing if previous attempt did not succeed

### Timeout

To implement this type of lock we need to store 2 variables:
- timestamp (unix epoch)
- timeout (duration, same units as timestamp)

It doesn't require client to release the lock this time, lock will simply be re-acquired when passed `ts/timeout` value is higher than stored `ts/timeout`:

```redis
-- $ts = current timestamp
-- $timeout = timeout
-- $score = floor($ts/$timeout)

zadd task gt ch $score task_id
```

for example:

```redis
-- $ts = 1445412480
-- $timeout = 3600 (seconds in hour)
-- $score = floor(1445412480/3600)

zadd task gt ch 401503 hourly:task_id
-- (integer) 1 // lock acquired
zadd task gt ch 401503 hourly:task_id
-- (integer) 0
zadd task gt ch 401504 hourly:task_id
-- (integer) 1 // an hour has passed, lock re-acquired
```

or:

```redis
-- $timeout = 86400 (seconds in day)
-- $score = floor(1445412480/86400)

zadd task gt ch 16729 hourly:task_id
-- (integer) 1 // lock acquired
zadd task gt ch 16729 hourly:task_id
-- (integer) 0
zadd task gt ch 16730 hourly:task_id
-- (integer) 1 // a day has passed, lock re-acquired
```

#### Notes

The approach is quite similar to one you can find in Time-series DBMS

##### Time-series

Let's have an agreement that we'll receive a metric point every 10 seconds (resolution)  
So for one minute we're going to have 7 time slots:

```
ts=0s  value=v0
ts=10s value=v1
ts=20s value=v2
ts=30s value=v3
ts=40s value=v4
ts=50s value=v5
ts=60s value=v6
```

Every time slot can store only one value according to its timestamp  

But it's not guaranteed that in real world our system will be able to satisfy the resolution condition and send points every 10 seconds:

```
ts=0s    value=v0
ts=10s   value=v1
ts=20s   value=v2
ts=30s   value=v3
ts=40s   value=v4
ts=50s   value=v5
ts=60s   value=v6
ts=1m10s no data
ts=1m15s value=v7 <-- received too late
ts=1m20s value=v8
```

By some heuristics it's possible to determine that the ts is actually `1m10s` not `1m15s` and recalculate it  
But what happens when we receive points with `1m19s` and `1m20s` for the same metric?

There's a strategy called `Last Write Wins` that allows us to simply rewrite the old `1m10s` no data with value we received at `1m15s` and get the following dataset:

```
ts=0s    value=v0
ts=10s   value=v1
ts=20s   value=v2
ts=30s   value=v3
ts=40s   value=v4
ts=50s   value=v5
ts=60s   value=v6
ts=1m10s value=v7
ts=1m20s value=v8
```

##### Locks

In our example, we simply replace the timestamp with new variable called score (timestamp/resolution):

```
score=floor(0/10)  score=0 state=s0
score=floor(10/10) score=1 state=s1
score=floor(20/10) score=2 state=s2
score=floor(30/10) score=3 state=s3
score=floor(40/10) score=4 state=s4
score=floor(50/10) score=5 state=s5
score=floor(60/10) score=6 state=s6
```

The main difference is that while working with time-series it's more convenient to use `Last Write Wins`  
Locking in our case is based on `First Write Wins` strategy

### State transition

This approach is quite similar to the previous one, but now we are going to use:
- current task status (instead of timestamp)
- list of task statuses we can use to start processing a task

For example, consider having the following statuses:
- done (also initial status)
- in_progress (client exclusive)
- failed

```redis
-- $status = task status

-- 0 = done
-- 1 = in_progress
-- 2 = failed

zadd task nx 0 task_id
-- (integer) 1
```

so we can lock any of `done` and `failed` by using `in_progress`:

```redis
zadd task xx ch 1 task_id
-- (integer) 1
```

and release the lock by setting `failed` or `done`:

```redis
zadd task xx ch 0 task_id
-- (integer) 1
```

We can also add status `timeout` but there are two limitations:

1. along with `failed` it's not guaranteed that client will be able to set this state  
   so it takes to set the timeout value for every task and launch another worker that will be setting the correct task statuses on specified interval
2. it's also possible to compute status `timeout` (instead of storing it in database) inside read operations  
   but that can lead to problems related with cases when API and database return different statuses
