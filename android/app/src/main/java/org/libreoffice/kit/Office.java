// SPDX-License-Identifier: MPL-2.0
package org.libreoffice.kit;

import androidx.annotation.Keep;
import java.nio.ByteBuffer;
import java.util.Objects;

/** 用 LibreOfficeKit 打开本机文档。 */
@Keep
public final class Office {
    private final ByteBuffer handle;

    Office(ByteBuffer handle) {
        this.handle = Objects.requireNonNull(handle);
    }

    public Document open(String url) {
        ByteBuffer document = documentLoadNative(url);
        return document == null ? null : new Document(document);
    }

    private native ByteBuffer documentLoadNative(String url);
}
