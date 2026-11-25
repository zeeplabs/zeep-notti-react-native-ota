package com.notti.ota.expo

import android.content.Context
import com.notti.ota.NottiOta
import expo.modules.core.interfaces.Package
import expo.modules.core.interfaces.ReactNativeHostHandler

class NottiOtaExpoPackage : Package {
  override fun createReactNativeHostHandlers(context: Context): List<ReactNativeHostHandler> =
    listOf(NottiOtaHostHandler { NottiOta.getJSBundleFile(context) })
}
