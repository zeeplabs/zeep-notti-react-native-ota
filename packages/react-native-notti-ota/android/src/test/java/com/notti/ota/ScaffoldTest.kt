package com.notti.ota

import org.junit.Assert.assertEquals
import org.junit.Test

class ScaffoldTest {
  @Test
  fun moduleNameMatchesTheJsSpec() {
    assertEquals("NottiOta", NottiOtaModule.NAME)
  }
}
