// SPDX-License-Identifier: MPL-2.0
package org.libreoffice.kit;

import android.content.Context;
import android.content.res.AssetManager;
import android.net.Uri;
import androidx.annotation.Keep;
import java.io.File;
import java.nio.ByteBuffer;

/** LibreOffice Android 原生引擎的初始化接口，类名与原生符号一致。 */
@Keep
public final class LibreOfficeKit {
    static {
        for (String library : new String[] {
            "nspr4", "plds4", "plc4", "nssutil3", "freebl3", "sqlite3",
            "softokn3", "nss3", "nssckbi", "nssdbm3", "smime3", "ssl3",
            "c++_shared", "lo-native-code"
        }) {
            System.loadLibrary(library);
        }
    }

    private LibreOfficeKit() {}

    public static Office open(Context context, File profile) {
        putenv("CONFIGURATION_LAYERS=xcsxcu:file:///assets/share/registry "
                + "res:file:///assets/share/registry user:" + Uri.fromFile(profile));
        if (!initializeNative(context.getApplicationInfo().dataDir,
                context.getCacheDir().getAbsolutePath(),
                context.getPackageResourcePath(), context.getAssets())) {
            throw new IllegalStateException("无法启动 Word 转换引擎");
        }
        return new Office(getLibreOfficeKitHandle());
    }

    private static native boolean initializeNative(
            String dataDir, String cacheDir, String apkPath, AssetManager assets);

    private static native ByteBuffer getLibreOfficeKitHandle();

    private static native void putenv(String value);
}
