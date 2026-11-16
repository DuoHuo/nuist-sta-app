// SPDX-License-Identifier: MPL-2.0
package org.libreoffice.kit;

import androidx.annotation.Keep;
import java.nio.ByteBuffer;

/** 用 LibreOfficeKit 导出文档并释放原生句柄。 */
@Keep
public final class Document implements AutoCloseable {
    private final ByteBuffer handle;

    Document(ByteBuffer handle) {
        this.handle = handle;
    }

    public boolean isText() {
        return getDocumentTypeNative() == 0;
    }

    public native void saveAs(String url, String format, String options);
    private native int getDocumentTypeNative();
    private native void destroy();

    @Override
    public void close() {
        destroy();
    }
}
