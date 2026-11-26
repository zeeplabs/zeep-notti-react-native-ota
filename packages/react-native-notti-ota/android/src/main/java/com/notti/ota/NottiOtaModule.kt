package com.notti.ota

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext

class NottiOtaModule(reactContext: ReactApplicationContext) : NativeNottiOtaSpec(reactContext) {
  private val listener: (ReleasePointer) -> Unit = { pointer ->
    emitOtaUpdateReady(
      Arguments.createMap().apply {
        putString("releaseId", pointer.releaseId)
        putBoolean("mandatory", pointer.mandatory)
      }
    )
  }

  init {
    NottiOta.updateReadyListener = listener
  }

  override fun getName(): String = NAME

  override fun getCurrentRelease(promise: Promise) {
    val releaseId = NottiOta.currentReleaseId()
    val result = Arguments.createMap()
    if (releaseId == null) result.putNull("releaseId") else result.putString("releaseId", releaseId)
    result.putBoolean("isEmbedded", releaseId == null)
    promise.resolve(result)
  }

  override fun invalidate() {
    if (NottiOta.updateReadyListener === listener) NottiOta.updateReadyListener = null
    super.invalidate()
  }

  companion object {
    const val NAME = "NottiOta"
  }
}
