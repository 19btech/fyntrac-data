package com.fyntrac.data.testdriver;

import org.springframework.core.io.InputStreamResource;

import java.io.InputStream;

public class NamedInputStreamResource extends InputStreamResource {
    private final String filename;

    public NamedInputStreamResource(InputStream inputStream, String filename) {
        super(inputStream);
        this.filename = filename;
    }

    @Override
    public String getFilename() {
        return filename;
    }

    @Override
    public long contentLength() {
        return -1; // unknown length, unless you know it ahead of time
    }
}
