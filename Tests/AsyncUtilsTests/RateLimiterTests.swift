//
//  RateLimiterTests.swift
//  AsyncUtils
//
//  Created by Matteo Ludwig on 21.05.25.
//  Licensed under the MIT-License included in the project.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//

import XCTest
@testable import AsyncUtils

final class RateLimiterTests: XCTestCase {


    func testLeakyBucketRegenerate() async throws {
        let rateLimiter = RateLimiter(.leakyBucket(tokenRate: 10))
        let consumeFirst = await rateLimiter.consumeToken()
        let firstConsumed = Date()
        XCTAssertTrue(consumeFirst)
        
        while Date().timeIntervalSince(firstConsumed) < 0.1 {
            let canConsume = await rateLimiter.consumeToken()
            XCTAssertFalse(canConsume)
            try await Task.sleep(for: .milliseconds(10))
            
        }
        let canConsume = await rateLimiter.consumeToken()
        XCTAssertTrue(canConsume)
    }

    func testLeakyBucketBlocking() async throws {
        let rateLimiter = RateLimiter(.leakyBucket(tokenRate: 100))
        let storage = TestingStorage()
        
        let count = 300
        for i in 0..<count {
            Task.detached {
                await storage.started(i)
                try await rateLimiter.blockUntilNextTokenAvailable()
                await storage.ended(i)
            }
        }
        
        try await Task.sleep(for: .seconds(3.5))
        let (_, ends, _) = await storage.data
        XCTAssertEqual(ends.count, count)
        
        let sortedEnds = ends.values.sorted()
        
        let deltaTime = sortedEnds.last!.timeIntervalSince(sortedEnds.first!)
        XCTAssertEqual(Double(count)/deltaTime, 100.0, accuracy: 0.5)
        
        for i in 1..<count {
            XCTAssertEqual(sortedEnds[i].timeIntervalSinceReferenceDate - sortedEnds[i-1].timeIntervalSinceReferenceDate,
                           0.01, accuracy: 0.01)
        }
    }
    
    
    func testLeakyBucketBlockingCancellation() async throws {
        let rateLimiter = RateLimiter(.leakyBucket(tokenRate: 1))
        let storage = TestingStorage()

        try await rateLimiter.tryConsumeToken()

        let waitTask = Task {
            do {
                try await rateLimiter.blockUntilNextTokenAvailable()
            } catch is CancellationError {
                await storage.incrementCounter()
            }
        }

        try await Task.sleep(for: .seconds(0.01))
        waitTask.cancel()
        try await Task.sleep(for: .seconds(0.01))

        let counter = await storage.counter
        XCTAssertEqual(counter, 1)
    }

    func testTryConsumeTokenThrowsWhenRateLimitExceeded() async throws {
        let rateLimiter = RateLimiter(.tokenBucket(maxTokens: 1, tokenRate: 10))

        let first = await rateLimiter.consumeToken()
        XCTAssertTrue(first)

        do {
            try await rateLimiter.tryConsumeToken()
            XCTFail("Expected RateLimitExceededError to be thrown")
        } catch {
            XCTAssertTrue((error as Error) is RateLimitExceededError)
        }
    }

    // MARK: - Bug regression tests

    /// Regression: when a waiter blocks after some time has passed since the bucket
    /// was last full, but `nextTokenRegenerate` is nil (because no whole token was
    /// regenerated in that interval), the regeneration task must sleep for the
    /// *remaining* time to the next token, not a full `1/tokenRate` from now.
    ///
    /// Setup: tokenRate=5 (one token per 0.2 s).
    ///   t=0.0  token consumed ->lastTokenRegenerate=t0, nextTokenRegenerate=nil
    ///   t=0.1  waiter blocks  ->next token is only 0.1 s away
    ///   t=0.2  token due
    ///
    /// The `fulfillment` call is made at t=0.1. From that moment:
    ///   Without fix: regen task sleeps full 1/tokenRate = 0.2 s
    ///               ->waiter unblocks 0.2 s after call (t=0.3 s total)->exceeds 0.15 s timeout->test FAILS
    ///   With fix:    regen task sleeps remaining 0.1 s
    ///               ->waiter unblocks 0.1 s after call (t=0.2 s total)->within 0.15 s timeout->test PASSES
    func testWaiterUnblocksAfterCorrectRemainingWait() async throws {
        let rateLimiter = RateLimiter(.leakyBucket(tokenRate: 5))

        let res1 = await rateLimiter.consumeToken()
        XCTAssertTrue(res1)
        let consumedAt = Date()

        // Advance half a token period (0.1 s). The next token is now only 0.1 s away,
        // but nextTokenRegenerate is still nil.
        try await Task.sleep(for: .seconds(0.1))

        let unblocked = expectation(description: "waiter unblocked")
        Task {
            try await rateLimiter.blockUntilNextTokenAvailable()
            unblocked.fulfill()
        }

        await fulfillment(of: [unblocked], timeout: 0.15)  // fails pre-fix

        XCTAssertGreaterThanOrEqual(-consumedAt.timeIntervalSinceNow, 0.15,
            "Waiter unblocked before the next token was due")
    }

    /// Regression: when the regeneration task fires before the cancellation Task
    /// reaches the actor, blockUntilNextTokenAvailable() can return without throwing
    /// on a cancelled task - consuming the token silently.
    ///
    /// The test is probabilistic: we cancel at 90% of the token period so the
    /// regen fires ~1 ms later, creating a tight race window. Over many iterations
    /// the race reliably occurs at least once.
    ///
    /// We assert **token conservation**: after the waiter completes (either path) and
    /// one full regen period has elapsed, exactly 1 token must be in the bucket.
    ///
    ///   Without fix: regen wins race->token consumed by cancelled task, not returned
    ///               ->tokensInBucket == 0 at t+20ms->FAILS
    ///   With fix:    token always returned (via post-check or regen to empty queue)
    ///               ->tokensInBucket == 1 at t+20ms->PASSES
    ///
    /// Using tokenRate=20 (50ms/token, cancel at 45ms) makes sleep-overshoot
    /// essentially impossible: Task.sleep would need to overshoot by 5ms on a 45ms
    /// sleep, whereas typical scheduler jitter is well under 1ms.
    func testCancellationRaceTokenConserved() async throws {
        // tokenRate 20->one token every 50 ms; cancel at 45 ms.
        // Wide margin eliminates sleep-overshoot false failures.
        for _ in 0..<30 {
            let rateLimiter = RateLimiter(.tokenBucket(maxTokens: 2, tokenRate: 20))
            let consumed1 = await rateLimiter.consumeToken()
            let consumed2 = await rateLimiter.consumeToken()
            XCTAssertTrue(consumed1)
            XCTAssertTrue(consumed2)

            let waitTask = Task<Bool, Never> {
                do {
                    try await rateLimiter.blockUntilNextTokenAvailable()
                    return true   // waiter got the token
                } catch {
                    return false  // threw CancellationError
                }
            }

            // Cancel just before the regen fires to maximise the intra-actor race window.
            // 45ms is 90% of the 50ms period; a sleep overshoot of 5ms on a 45ms sleep
            // is negligible on any real scheduler.
            try await Task.sleep(for: .milliseconds(45))
            waitTask.cancel()
            _ = await waitTask.value

            // Wait past the full regen period so any pending regeneration has fired.
            // At this point (t ~= 60ms, next regen at 100ms), exactly 1 token must
            // be in the bucket:
            //   - waiter threw->token was either returned by post-check or regen fired
            //     to empty queue->tokensInBucket == 1
            //   - waiter returned (BUG: token consumed by cancelled task, not returned)
            //    ->regen has not had time to fire again->tokensInBucket == 0
            try await Task.sleep(for: .milliseconds(15))
            let available = await rateLimiter.tokensInBucket
            XCTAssertEqual(available, 1,
                "Token conservation violated: after one regen period, bucket must hold exactly 1 token")
        }
    }

    /// tokenRate: 0 causes a division producing Double.infinity, which later
    /// crashes with a UInt64(.infinity) trap in the regeneration task's sleep.
    /// The synchronous consume path should be safe: the bucket starts full,
    /// so the first consume succeeds and the second correctly returns false
    /// without triggering the broken sleep path.
    func testZeroTokenRateSynchronousConsumeDoesNotCrash() async throws {
        let rateLimiter = RateLimiter(.leakyBucket(tokenRate: 0))

        // Leaky bucket starts with 1 token - first consume must succeed.
        let first = await rateLimiter.consumeToken()
        XCTAssertTrue(first, "First consume should succeed (bucket starts full)")

        // No regeneration possible at rate 0 - second consume must fail.
        let second = await rateLimiter.consumeToken()
        XCTAssertFalse(second, "Second consume should fail (no regeneration at tokenRate 0)")
    }

    /// Same crash risk exists for a token bucket with tokenRate: 0.
    func testZeroTokenRateTokenBucketSynchronousConsumeDoesNotCrash() async throws {
        let rateLimiter = RateLimiter(.tokenBucket(maxTokens: 3, tokenRate: 0))

        // Bucket starts full - first 3 consumes must succeed.
        for _ in 0..<3 {
            let consumed = await rateLimiter.consumeToken()
            XCTAssertTrue(consumed)
        }

        // Fourth consume: bucket empty, no regeneration at rate 0 - must fail.
        let fourth = await rateLimiter.consumeToken()
        XCTAssertFalse(fourth)
    }

}
