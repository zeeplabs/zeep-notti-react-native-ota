package com.notti.ota.expo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.fail
import org.junit.Test

class NottiOtaHostHandlerTest {
  @Test
  fun aFatalInstanceErrorIsRethrown() {
    val error = RuntimeException("fatal JS error")
    try {
      NottiOtaHostHandler { null }.onReactInstanceException(false, error)
      fail("the instance error was swallowed")
    } catch (e: RuntimeException) {
      assertSame(error, e)
    }
  }

  @Test
  fun releaseBuildsLoadTheSelectedBundle() {
    val path = "/data/notti-ota/releases/x/index.android.bundle"
    assertEquals(path, NottiOtaHostHandler { path }.getJSBundleFile(false))
    assertNull(NottiOtaHostHandler { null }.getJSBundleFile(false))
  }

  @Test
  fun developerSupportNeverAsksForALiveUpdateAndTurnsTheSessionOff() {
    var asked = false
    var turnedOff = false
    assertNull(NottiOtaHostHandler({ turnedOff = true }) { asked = true; "/x" }.getJSBundleFile(true))
    assertEquals(false, asked)
    assertEquals(true, turnedOff)
  }
}
