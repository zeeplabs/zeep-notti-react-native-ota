package com.notti.ota

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageInfo
import android.os.Bundle
import androidx.test.core.app.ApplicationProvider
import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.JavaOnlyMap
import com.facebook.react.bridge.BridgeReactContext
import com.facebook.react.bridge.ReadableMap
import com.facebook.react.bridge.WritableMap
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.Implementation
import org.robolectric.annotation.Implements
import java.io.File

/** `Arguments.createMap()` needs the React Native JNI library; a Java map is enough for the JVM. */
@Implements(Arguments::class)
class ShadowArguments {
  companion object {
    @JvmStatic
    @Implementation
    fun createMap(): WritableMap = JavaOnlyMap()
  }
}

/** Records what the TurboModule hands to the codegen emitter instead of crossing JSI. */
@Implements(NativeNottiOtaSpec::class)
class ShadowNativeNottiOtaSpec {
  @Implementation
  protected fun emitOtaUpdateReady(value: ReadableMap) {
    emitted += value
  }

  companion object {
    val emitted = mutableListOf<ReadableMap>()
  }
}

@RunWith(RobolectricTestRunner::class)
@Config(
  shadows = [ShadowArguments::class, ShadowNativeNottiOtaSpec::class],
  instrumentedPackages = ["com.facebook.react.bridge", "com.notti.ota"]
)
class NottiOtaModuleTest {
  private val context = ApplicationProvider.getApplicationContext<Application>()
  private val running = "7d4f8a2e-1b3c-4e5f-9a6b-0c1d2e3f4a5b"
  private val ready = "1e2d3c4b-5a69-4788-9a0b-1c2d3e4f5a6b"

  @Before
  @After
  fun reset() {
    NottiOta.resetForTests()
    ShadowNativeNottiOtaSpec.emitted.clear()
  }

  private fun configureWithStable(releaseId: String): File {
    shadowOf(context.packageManager).installPackage(
      PackageInfo().apply {
        packageName = context.packageName
        versionName = "1.0"
        lastUpdateTime = 1
        applicationInfo = ApplicationInfo().apply {
          packageName = context.packageName
          metaData = Bundle().apply {
            putString(OTAConfig.KEY_APP_ID, "9c1d2e3f-4a5b-4c6d-8e7f-0a1b2c3d4e5f")
            putString(OTAConfig.KEY_BASE_URL, "https://push.example.com")
            putString(OTAConfig.KEY_CLIENT_KEY, "ck")
            putString(OTAConfig.KEY_CHANNEL, "production")
            putString(OTAConfig.KEY_RUNTIME_VERSION, "1.4.0")
            putString(OTAConfig.KEY_PUBLIC_KEYS, "${Fixtures.keyId}:${Fixtures.publicKeyBase64}")
          }
        }
      }
    )
    val store = OTAStateStore(File(context.filesDir, "notti-ota"))
    val state = store.open(BinaryIdentity.of(context as Context)).copy(stable = ReleasePointer(releaseId, "index.android.bundle"))
    val bundle = File(store.releaseDir(releaseId), "index.android.bundle").apply { parentFile!!.mkdirs(); writeText("x") }
    store.save(state)
    return bundle
  }

  @Test
  fun aReadyReleaseIsEmittedToJsAsOtaUpdateReady() {
    val module = NottiOtaModule(BridgeReactContext(context))

    NottiOta.releaseReady(ReleasePointer(ready, "index.android.bundle", mandatory = true))
    NottiOta.releaseReady(ReleasePointer(running, "index.android.bundle", mandatory = false))

    assertEquals(2, ShadowNativeNottiOtaSpec.emitted.size)
    val first = ShadowNativeNottiOtaSpec.emitted[0]
    assertEquals(ready, first.getString("releaseId"))
    assertTrue(first.getBoolean("mandatory"))
    assertEquals(setOf("releaseId", "mandatory"), first.toHashMap().keys)
    val second = ShadowNativeNottiOtaSpec.emitted[1]
    assertEquals(running, second.getString("releaseId"))
    assertFalse(second.getBoolean("mandatory"))

    module.invalidate()
    NottiOta.releaseReady(ReleasePointer(ready, "index.android.bundle", mandatory = true))
    assertEquals("an invalidated module no longer emits", 2, ShadowNativeNottiOtaSpec.emitted.size)
  }

  @Test
  fun aReadyReleaseNeverRestartsTheAppOrSwapsTheRunningBundle() {
    val runningBundle = configureWithStable(running)
    assertEquals(runningBundle.absolutePath, NottiOta.getJSBundleFile(context))
    val activity = Robolectric.buildActivity(Activity::class.java).setup()
    NottiOtaModule(BridgeReactContext(context))

    NottiOta.releaseReady(ReleasePointer(ready, "index.android.bundle", mandatory = true))

    assertEquals(1, ShadowNativeNottiOtaSpec.emitted.size)
    assertEquals(running, NottiOta.currentReleaseId())
    assertEquals(runningBundle.absolutePath, NottiOta.getJSBundleFile(context))
    assertFalse(activity.get().isFinishing)
    assertNull(shadowOf(context).nextStartedActivity)
    assertNull(shadowOf(activity.get()).nextStartedActivity)
  }
}
