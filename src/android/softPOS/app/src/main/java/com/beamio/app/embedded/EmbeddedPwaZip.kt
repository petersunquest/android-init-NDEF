package com.beamio.app.embedded

import java.io.BufferedInputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.util.zip.ZipInputStream

internal object EmbeddedPwaZip {
    fun unzip(input: InputStream, destDir: File) {
        if (destDir.exists()) {
            destDir.deleteRecursively()
        }
        destDir.mkdirs()
        ZipInputStream(BufferedInputStream(input)).use { zis ->
            var entry = zis.nextEntry
            while (entry != null) {
                if (!entry.isDirectory) {
                    val outFile = File(destDir, entry.name)
                    val destCanonical = destDir.canonicalPath + File.separator
                    val fileCanonical = outFile.canonicalPath
                    if (!fileCanonical.startsWith(destCanonical)) {
                        throw SecurityException("Zip slip: ${entry.name}")
                    }
                    outFile.parentFile?.mkdirs()
                    FileOutputStream(outFile).use { fos -> zis.copyTo(fos) }
                }
                zis.closeEntry()
                entry = zis.nextEntry
            }
        }
        removeMacOsMetadata(destDir)
    }

    fun removeMacOsMetadata(dir: File) {
        File(dir, "__MACOSX").deleteRecursively()
    }
}
