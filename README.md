# AsyncUtils
![iOS 16+](https://img.shields.io/badge/iOS-16%2B-blue.svg)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue.svg)
![watchOS 9+](https://img.shields.io/badge/watchOS-9%2B-blue.svg)
![tvOS 16+](https://img.shields.io/badge/tvOS-16%2B-blue.svg)
![Swift 5.10+](https://img.shields.io/badge/Swift-5.10%2B-orange.svg)
![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)
[![Docs: GitHub Pages](https://img.shields.io/badge/Docs-GitHub%20Pages-2ea44f?logo=github)](https://mldwg.github.io/AsyncUtils/)

A Swift concurrency utility library for Apple platforms. AsyncUtils fills gaps left by the standard library: controlled queues for concurrency, async semaphores, rate limiting, and bridging between Swift concurrency and legacy GCD/`OperationQueue` APIs.

**Requirements:** iOS 16+ / macOS 13+ / watchOS 9+ / tvOS 16+, Swift 5.10+

## TaskQueue

A FIFO task queue that runs up to a configurable number of tasks concurrently. Task can either be pushed to the queue, pulled by the queue when it is empty or a combination of both.

**Useful when** you have more work to do than you want running at once, like downloading hundreds of files without saturating the network, or processing a batch of images without spawning an unbounded number of tasks.

**Key features:**
- Configurable `maxConcurrentSlots` (can be changed at runtime)
- Slot-weighted tasks: a single task can claim more than one slot
- `addAndWait` to await a task's result inline
- `waitForAll`, `cancelQueued`, `cancelAll`, `cancelAllAndWait`

```swift
let queue = TaskQueue(maxConcurrentSlots: 4)

// Fire-and-forget
await queue.add {
    await processImage(image)
}

// Await the result. Cancellation of the Task calling addAndWait is propagated to the queued Task automatically.
let result = try await queue.addAndWait {
    return await fetchData(from: url)
}

// A heavy task that claims 2 of the 4 available slots
let ticket = await queue.add(slots: 2) {
    await runExpensiveOperation()
}

// Cancel a specific task by its ticket
await queue.cancel(ticket)

// If the queue has nothing to do, schedule deferrable background work
await queue.setTaskProvider { freeSlots in
    if freeSlots >= 4 {
        return QueueTask(slots: 4) { try await intenseBackgroundCleanup()}
    } else {
        return nil
    }
}

// Wait until all currently queued/running tasks finish
try await queue.waitForAll()

// Cancel everything that hasn't started yet
await queue.cancelQueued()
```

---

## AsyncSemaphore

An `async`/`await`-native semaphore, the Swift concurrency equivalent of `DispatchSemaphore`. Waiters are resumed in FIFO order and support cooperative cancellation.

**Useful when** you need to guard a shared resource that only supports a fixed number of concurrent accessors, like a connection pool, a file handle, or any API with a hard concurrency limit.

```swift
let semaphore = AsyncSemaphore(value: 3) // allow 3 concurrent holders

// Use .run(_:) to acquire/release automatically
let result = try await semaphore.run {
    return await doWork()
}

// Or acquire and release manually
try await semaphore.wait()
defer { semaphore.signal() }
await doWork()
```

---

## RateLimiter

A token-bucket / leaky-bucket rate limiter. Async waiters are queued in FIFO order and resumed as tokens become available.

**Useful when** you need to respect an external rate limit, like staying within an API's requests-per-second quota, or when you want to smooth out bursts of work to avoid overloading a downstream service.

```swift
// Leaky bucket: strictly one request per 200 ms (5 req/s)
let limiter = RateLimiter(.leakyBucket(tokenRate: 5))

// Token bucket: burst up to 10, refill at 2 tokens/s
let limiter = RateLimiter(.tokenBucket(maxTokens: 10, tokenRate: 2))

// Async, suspends until a token is available
try await limiter.blockUntilNextTokenAvailable()
await makeAPIRequest()

// Sync, returns false if no token is available right now
if await limiter.consumeToken() {
    makeAPIRequest()
}

// Sync, throws if rate limit is exceeded
try await limiter.tryConsumeToken()
```

---

## AsyncOperation

An `Operation` subclass that wraps `async`/`await` work. Lets you schedule Swift concurrency code in an `OperationQueue`, including support for `maxConcurrentOperationCount`, dependencies between operations, and `cancelAllOperations()`.

Cancellation propagates to the underlying `Task`, so cooperative cancellation works as expected.

**Useful when** you're working with existing `OperationQueue`-based infrastructure, like a legacy codebase or a framework that vends `OperationQueue` hooks and want to write the actual work in modern async/await without rewriting the surrounding coordination.

```swift
let operationQueue = OperationQueue()
operationQueue.maxConcurrentOperationCount = 2

// Convenience overload on OperationQueue
operationQueue.addOperation {
    await processItem(item)
}

// Or construct explicitly to set dependencies
let op1 = AsyncOperation { await stepOne() }
let op2 = AsyncOperation { await stepTwo() }
op2.addDependency(op1)

operationQueue.addOperations([op1, op2], waitUntilFinished: false)
```

---

## Task Extensions

**Useful when** you need small, one-off async conveniences, like scheduling work after a delay, enforcing a deadline on an operation, or calling a synchronous GCD-based API from an async context.

### Delayed execution

Start a task after a delay without blocking the caller.

```swift
Task.delayed(by: .seconds(2)) {
    await sendReminder()
}
```

### Timeout

Cancel a task automatically if it runs too long.

```swift
let result = try await Task.withTimeout(cancelAfter: .seconds(10)) {
    return try await fetchRemoteConfig()
}
```

### Dispatch on a DispatchQueue

Bridge synchronous GCD-based APIs into async/await cleanly.

```swift
let data = try await Task.dispatch(on: .global(qos: .userInitiated)) {
    return try Data(contentsOf: fileURL)
}
```

---

## Installation

Add the package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mldwg/AsyncUtils", from: "1.1.0"),
],
targets: [
    .target(name: "MyTarget", dependencies: ["AsyncUtils"]),
]
```

---

## License

MIT. See the license header in each source file.
