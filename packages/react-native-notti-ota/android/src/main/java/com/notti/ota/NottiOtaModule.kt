package com.notti.ota

import com.facebook.react.bridge.Arguments
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext

class NottiOtaModule(reactContext: ReactApplicationContext) : NativeNottiOtaSpec(reactContext) {

  override fun getName(): String = NAME

  override fun getCurrentRelease(promise: Promise) {
    val result = Arguments.createMap()
    result.putNull("releaseId")
    result.putBoolean("isEmbedded", true)
    promise.resolve(result)
  }

  companion object {
    const val NAME = "NottiOta"
  }
}
