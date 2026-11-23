package com.example.shortplay

import okhttp3.Dns
import okhttp3.OkHttpClient
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.InetAddress
import java.net.ServerSocket
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class HttpRangeDiagnosticsTest {
    @Test
    fun sizeProbeRetainsOnlyTheHttpStatusForPlaybackDiagnostics() = withResponse(403) { url ->
        val seenStatus = AtomicInteger(-1)
        val logs = mutableListOf<String>()
        val client = HttpRangeClient(
            client = OkHttpClient.Builder().callTimeout(5, TimeUnit.SECONDS).build(),
            logError = logs::add,
            onHttpStatus = { _, status -> seenStatus.set(status) },
        )

        assertEquals(-1L, client.httpSize(url))
        assertEquals(403, seenStatus.get())
        assertTrue(logs.isNotEmpty())
        assertTrue(logs.joinToString().contains("phase=size"))
        assertTrue(logs.joinToString().contains("host="))
        assertTrue(logs.joinToString().contains("status=403"))
        assertFalse(logs.joinToString().contains("127.0.0.1"))
        assertFalse(logs.joinToString().contains("token=do-not-log"))
        assertFalse(logs.joinToString().contains("cdn.invalid"))
    }

    @Test
    fun dnsFailuresLogOnlyAHostFingerprint() {
        val logs = mutableListOf<String>()
        val client = HttpRangeClient(
            client = OkHttpClient.Builder()
                .dns(object : Dns {
                    override fun lookup(hostname: String): List<InetAddress> =
                        throw UnknownHostException("redacted")
                })
                .callTimeout(5, TimeUnit.SECONDS)
                .build(),
            logError = logs::add,
        )

        assertEquals(-1L, client.httpSize("http://media.example.invalid/video?token=do-not-log"))
        val joined = logs.joinToString("\n")
        assertTrue(joined.contains("phase=size"))
        assertTrue(joined.contains("error=UnknownHostException"))
        assertTrue(joined.contains("attempt=3"))
        assertTrue(joined.contains("host="))
        assertFalse(joined.contains("media.example.invalid"))
        assertFalse(joined.contains("token=do-not-log"))
    }

    @Test
    fun streamedResponseStatusIsRetainedForLaterPlaybackErrorReporting() = withResponse(403) { url ->
        val seenStatus = AtomicInteger(-1)
        val client = HttpRangeClient(
            client = OkHttpClient.Builder().callTimeout(5, TimeUnit.SECONDS).build(),
            logError = {},
            onHttpStatus = { _, status -> seenStatus.set(status) },
        )

        val id = client.streamPrepare(url, 0, 1024)
        assertTrue(id > 0)
        assertFalse(client.streamConnect(id))
        assertEquals(403, seenStatus.get())
        client.streamClose(id)
    }

    private fun withResponse(status: Int, body: (String) -> Unit) {
        val server = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1"))
        val worker = Thread {
            server.accept().use { socket ->
                val reader = BufferedReader(InputStreamReader(socket.getInputStream()))
                while (reader.readLine()?.isNotEmpty() == true) {
                    // Consume request headers; request target deliberately contains a fake secret.
                }
                socket.getOutputStream().apply {
                    write("HTTP/1.1 $status Test\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
                    flush()
                }
            }
        }
        worker.start()
        try {
            body("http://127.0.0.1:${server.localPort}/video?token=do-not-log")
        } finally {
            server.close()
            worker.join(5_000)
        }
    }
}
