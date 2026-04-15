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

    // MARK: - Bug regression tests

    /// tokenRate: 0 causes a division producing Double.infinity, which later
    /// crashes with a UInt64(.infinity) trap in the regeneration task's sleep.
    /// The synchronous consume path should be safe: the bucket starts full,
    /// so the first consume succeeds and the second correctly returns false
    /// without triggering the broken sleep path.
    func testZeroTokenRateSynchronousConsumeDoesNotCrash() async throws {
        let rateLimiter = RateLimiter(.leakyBucket(tokenRate: 0))

        // Leaky bucket starts with 1 token — first consume must succeed.
        let first = await rateLimiter.consumeToken()
        XCTAssertTrue(first, "First consume should succeed (bucket starts full)")

        // No regeneration possible at rate 0 — second consume must fail.
        let second = await rateLimiter.consumeToken()
        XCTAssertFalse(second, "Second consume should fail (no regeneration at tokenRate 0)")
    }

    /// Same crash risk exists for a token bucket with tokenRate: 0.
    func testZeroTokenRateTokenBucketSynchronousConsumeDoesNotCrash() async throws {
        let rateLimiter = RateLimiter(.tokenBucket(maxTokens: 3, tokenRate: 0))

        // Bucket starts full — first 3 consumes must succeed.
        for _ in 0..<3 {
            let consumed = await rateLimiter.consumeToken()
            XCTAssertTrue(consumed)
        }

        // Fourth consume: bucket empty, no regeneration at rate 0 — must fail.
        let fourth = await rateLimiter.consumeToken()
        XCTAssertFalse(fourth)
    }

}
