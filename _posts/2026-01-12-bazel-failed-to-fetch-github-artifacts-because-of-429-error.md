---
layout: post
title: "Bazel Fetch Failed with 429 Error: A TLS Fingerprinting Mystery"
date: 2026-01-12
---
# How I Wasted a Weekend on a 429 Error (and Learned About TLS Fingerprinting)

I wanted to contribute some changes to [Ray](https://github.com/ray-project/ray), the distributed computing framework. Ray uses Bazel for its build system. Should be simple, right? Clone, build, hack. Instead I spent two days chasing down why GitHub kept rejecting my requests.

## The Problem

If you want to follow along, you'll need Java 11. I use [SDKMAN](https://sdkman.io/):

```bash
sdk install java 11.0.21-tem
sdk use java 11.0.21-tem
```

Then clone Ray and try to fetch dependencies:

```bash
git clone -c core.symlinks=true https://github.com/ray-project/ray.git
cd ray
git checkout ray-2.53.0
bazel fetch //...
```

And you get this:

```
ERROR: Error computing the main repository mapping: no such package '@rules_foreign_cc_thirdparty//openssl': java.io.IOException: Error downloading [https://github.com/bazelbuild/rules_foreign_cc/archive/refs/tags/0.9.0.tar.gz] to /private/var/tmp/_bazel_hs/edd65551cf065ba367af09f024ad2428/external/rules_foreign_cc_thirdparty/temp2869363689784314327/0.9.0.tar.gz: GET returned 429 Too Many Requests
```

Ray 2.53.0 uses Bazel 6.5.0 and pulls in dozens of external dependencies from GitHub. Every single one of those fetches was failing.

## First Attempt: It's Probably Rate Limiting

Quick googling turned up [a bunch](https://github.com/orgs/community/discussions/177971) [of threads](https://github.com/orgs/community/discussions/159123) about GitHub returning 429s due to rate limiting. GitHub also published [an announcement](https://github.blog/changelog/2025-05-08-updated-rate-limits-for-unauthenticated-requests/) about stricter limits on unauthenticated archive downloads.

Okay, so I need to authenticate. I added my credentials to `.netrc`:

```
machine github.com
login my_username
password my_token

machine api.github.com
login my_username
password my_token
```

Verified it worked with curl:

```bash
curl --netrc https://api.github.com/user
```

Great. Re-ran `bazel fetch //...` and... got a 404.

What?

The error changed from 429 to 404 when I added credentials, and back to 429 when I removed them. So Bazel was definitely sending *something*, but I couldn't figure out what was actually happening on the wire. In retrospect I should've just fired up Wireshark right then. Would've saved me hours.

Instead I found [this PR](https://github.com/bazelbuild/bazel/pull/25385) about Bazel mishandling authentication on redirects. But it was already merged, so I'd need to build Bazel from source to test an older version. I wasn't ready to go down that rabbit hole yet.

## Second Attempt: Building Bazel from Source

Narrator: I went down that rabbit hole.

I followed the [official docs](https://bazel.build/install/compile-source#build-bazel-on-unixes) to build Bazel from source. Immediately hit the same 429 error because—of course—building Bazel also requires fetching things from GitHub.

Fortunately there's a [bootstrap method](https://bazel.build/install/compile-source#bootstrap-bazel) using `compile.sh` that doesn't need an existing Bazel installation. After fighting with some clang version issues on macOS 26, I finally got Bazel 6.5.0 built from the [dist tarball](https://github.com/bazelbuild/bazel/releases/download/6.5.0/bazel-6.5.0-dist.zip).

I carefully ported the relevant changes from that authentication PR into Bazel 6.5.0, rebuilt it, and ran `bazel fetch //...` again.

Still 429.

So much for the authentication theory.

## Third Attempt: Actually Figuring This Out

At this point I was frustrated enough to do what I should've done from the start: systematically isolate the problem. I started with the simplest possible Java HTTP code and added complexity until it broke.

**Plain Java HttpURLConnection:**

```java
URL url = new URL("https://github.com/bazelbuild/rules_jvm_external/archive/2.10.tar.gz");
HttpURLConnection connection = (HttpURLConnection) url.openConnection(Proxy.NO_PROXY);
connection.setRequestProperty("User-Agent", "Bazel/6.5.0");
connection.connect();
System.out.println("Response code: " + connection.getResponseCode());
```

This returned 301 (redirect). Fine.

**With Bazel's proxy helper:** Still 301.

**With Bazel's full HttpConnector class:** 429.

So something in Bazel's HTTP handling was triggering the error. I modified my test to manually follow the redirect chain:

```
github.com/bazelbuild/... → 301 (repo was renamed)
github.com/bazel-contrib/... → 302 (redirect to codeload)
codeload.github.com/... → 429
```

The 429 was coming from `codeload.github.com`, not `github.com`. That's the subdomain GitHub uses to actually serve archive downloads.

I tested a direct request to codeload:

```java
URL url = new URL("https://codeload.github.com/bazel-contrib/rules_jvm_external/tar.gz/refs/tags/2.10");
HttpURLConnection connection = (HttpURLConnection) url.openConnection(Proxy.NO_PROXY);
```

429.

But curl worked fine:

```bash
curl -v "https://codeload.github.com/bazel-contrib/rules_jvm_external/tar.gz/refs/tags/2.10" 2>&1 | grep "< HTTP"
# < HTTP/2 200
```

No authentication needed. Just... worked.

Why would curl succeed where Java's HttpURLConnection fails, making the exact same request to the exact same URL?

## TLS Fingerprinting

The answer is that they're not making the exact same request. They look the same at the HTTP level, but they look completely different at the TLS level.

TLS fingerprinting (sometimes called JA3 fingerprinting) analyzes the TLS handshake to identify what kind of client is connecting. Different TLS implementations offer different cipher suites in different orders, support different extensions, and generally have distinctive "fingerprints." This all happens *before* any HTTP traffic, which is why authentication headers don't help—the server has already decided to block you before it even sees your headers.

Java's `HttpURLConnection` has a distinctive fingerprint that GitHub apparently doesn't like. Curl has a different one. So does Java 11's newer `HttpClient`:

```java
HttpClient client = HttpClient.newBuilder()
    .followRedirects(HttpClient.Redirect.NEVER)
    .connectTimeout(Duration.ofSeconds(5))
    .build();

HttpRequest request = HttpRequest.newBuilder()
    .uri(URI.create("https://codeload.github.com/bazel-contrib/rules_jvm_external/tar.gz/refs/tags/2.10"))
    .header("User-Agent", "Bazel/7.0.0")
    .GET()
    .build();

HttpResponse<String> response = client.send(request, HttpResponse.BodyHandlers.ofString());
System.out.println("Response code: " + response.statusCode());
// 200
```

Java 11's `HttpClient` returns 200. Same JVM, same machine, same URL. Different HTTP client implementation, different TLS fingerprint, different result.

## The Fix

The safest fix was to use `HttpClient` specifically for `codeload.github.com` requests, leaving everything else alone. I added detection for codeload URLs and a wrapper to make the new client compatible with the existing code:

```java
private static boolean isCodeloadGitHub(URL url) {
    String host = url.getHost();
    return host != null && host.equals("codeload.github.com");
}

public URLConnection connect(URL url, Function<URL, ImmutableMap<String, List<String>>> requestHeaders)
    throws IOException {

    while (true) {
        if (isCodeloadGitHub(url)) {
            try {
                return connectWithJava11HttpClient(url, requestHeaders);
            } catch (RedirectException e) {
                url = e.getRedirectUrl();
                continue;
            }
        }
        // ... existing HttpURLConnection logic for everything else
    }
}
```

I won't paste the full `connectWithJava11HttpClient` implementation here, but it's basically just building an `HttpRequest`, sending it with the shared `HttpClient` instance, and wrapping the response in a `URLConnection`-compatible class.

After rebuilding Bazel with this change, `bazel fetch //...` finally worked.

## What I Learned

The obvious takeaway is that TLS fingerprinting exists and can bite you when you least expect it. But honestly the bigger lesson for me was about debugging methodology.

I wasted a lot of time because I got fixated on the authentication hypothesis without properly validating it. I should have:

1. Used Wireshark immediately to see what was actually going over the wire
2. Isolated the problem systematically from the start instead of diving into Bazel's codebase
3. Noticed earlier that curl worked without auth—that was a huge clue that auth wasn't the issue

The incremental testing approach—start simple, add complexity until it breaks—is obvious in retrospect but I needed the frustration of failed attempts before I slowed down and did it properly.

Also: not all HTTP clients are created equal. `HttpURLConnection` has been around since Java 1.1 and has a very distinctive TLS fingerprint. If you're hitting weird blocks from services that should work, trying a different HTTP client is worth a shot.

---

For the curious:
- [JA3 fingerprinting](https://github.com/salesforce/ja3) explains how TLS fingerprinting works
- The fix lives in `HttpConnector.java` with tests in `HttpConnectorTest.java`
