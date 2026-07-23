package a;

import java.io.*;
import java.net.*;
import javax.microedition.io.*;
import javax.net.ssl.*;
import java.util.*;
import java.security.*;

/**
 * WsC — WebSocket SocketConnection for J2ME
 *
 * Thay thế javax.microedition.io.Connector trong a.J:
 *   - Connector.open("socket://host:port") → WsC.open("socket://host:port")
 *   - Kết nối qua wss://REPLIT_DOMAIN:443/ws
 *   - Wrap DataInputStream/DataOutputStream với WebSocket frame codec
 *
 * Compile: javac -source 8 -target 8 WsC.java
 */
public class WsC implements SocketConnection {

    // ==== CONFIG — patcher thay thế chuỗi 70 ký tự này (khớp domain Replit) ====
    private static final String WS_HOST =
        "REPLIT_HOST_PLACEHOLDER_XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX";
    private static final int WS_PORT = 443;
    private static final String WS_PATH = "/ws";
    // ===========================================================

    private final Socket socket;
    private final WsInputStream wsIn;
    private final WsOutputStream wsOut;
    private boolean closed = false;

    private WsC(Socket socket, WsInputStream wsIn, WsOutputStream wsOut) {
        this.socket = socket;
        this.wsIn = wsIn;
        this.wsOut = wsOut;
    }

    /**
     * Entry point — called by a.J in place of Connector.open(url).
     * url ignored; always connects to WS_HOST:WS_PORT/WS_PATH via TLS.
     */
    public static Connection open(String url) throws IOException {
        return connect();
    }

    private static WsC connect() throws IOException {
        // 1. TLS socket
        SSLSocket sock = createTlsSocket();

        InputStream rawIn   = sock.getInputStream();
        OutputStream rawOut = sock.getOutputStream();

        // 2. WebSocket handshake
        String key = generateKey();
        doHandshake(rawOut, rawIn, key);

        // 3. Wrap streams
        WsOutputStream wsOut = new WsOutputStream(rawOut);
        WsInputStream  wsIn  = new WsInputStream(rawIn);

        return new WsC(sock, wsIn, wsOut);
    }

    private static SSLSocket createTlsSocket() throws IOException {
        SSLSocketFactory factory =
            (SSLSocketFactory) SSLSocketFactory.getDefault();
        SSLSocket sock = (SSLSocket) factory.createSocket(WS_HOST, WS_PORT);
        sock.setTcpNoDelay(true);
        sock.startHandshake();
        return sock;
    }

    private static String generateKey() {
        byte[] nonce = new byte[16];
        new Random().nextBytes(nonce);
        return Base64.getEncoder().encodeToString(nonce);
    }

    private static void doHandshake(OutputStream out, InputStream in, String key)
            throws IOException {
        // Send HTTP Upgrade request
        PrintWriter pw = new PrintWriter(new OutputStreamWriter(out, "ASCII"), false);
        pw.print("GET " + WS_PATH + " HTTP/1.1\r\n");
        pw.print("Host: " + WS_HOST + "\r\n");
        pw.print("Upgrade: websocket\r\n");
        pw.print("Connection: Upgrade\r\n");
        pw.print("Sec-WebSocket-Key: " + key + "\r\n");
        pw.print("Sec-WebSocket-Version: 13\r\n");
        pw.print("\r\n");
        pw.flush();

        // Read response headers
        StringBuilder sb = new StringBuilder();
        int prev = -1;
        int b;
        while ((b = in.read()) != -1) {
            sb.append((char) b);
            // Detect \r\n\r\n end of headers
            String s = sb.toString();
            if (s.endsWith("\r\n\r\n")) break;
        }
        String resp = sb.toString();
        if (!resp.startsWith("HTTP/1.1 101") && !resp.startsWith("HTTP/1.0 101")) {
            throw new IOException("WebSocket handshake failed: " + resp.substring(0, Math.min(resp.length(), 80)));
        }
    }

    // ---- SocketConnection interface ----

    @Override
    public DataInputStream openDataInputStream() throws IOException {
        return new DataInputStream(wsIn);
    }

    @Override
    public DataOutputStream openDataOutputStream() throws IOException {
        return new DataOutputStream(wsOut);
    }

    @Override
    public InputStream openInputStream() throws IOException {
        return wsIn;
    }

    @Override
    public OutputStream openOutputStream() throws IOException {
        return wsOut;
    }

    @Override
    public void close() throws IOException {
        if (closed) return;
        closed = true;
        try { wsOut.sendClose(); } catch (Exception ignored) {}
        socket.close();
    }

    // SocketConnection metadata (not used by NRO client but must implement)
    @Override public String getAddress()      { return WS_HOST; }
    @Override public String getLocalAddress() { return "127.0.0.1"; }
    @Override public int getPort()            { return WS_PORT; }
    @Override public int getLocalPort()       { return 0; }
    @Override public void setSocketOption(byte option, int value) throws IllegalArgumentException, IOException {}
    @Override public int getSocketOption(byte option) throws IllegalArgumentException, IOException { return 0; }

    // ====================================================================
    // WebSocket frame decoder — wraps raw InputStream
    // ====================================================================
    private static final class WsInputStream extends InputStream {
        private final InputStream raw;
        private byte[] payload = new byte[0];
        private int payloadPos = 0;

        WsInputStream(InputStream raw) { this.raw = raw; }

        @Override
        public int read() throws IOException {
            while (payloadPos >= payload.length) {
                readFrame();
            }
            return payload[payloadPos++] & 0xff;
        }

        @Override
        public int read(byte[] buf, int off, int len) throws IOException {
            while (payloadPos >= payload.length) {
                readFrame();
            }
            int avail = payload.length - payloadPos;
            int n = Math.min(len, avail);
            System.arraycopy(payload, payloadPos, buf, off, n);
            payloadPos += n;
            return n;
        }

        private void readFrame() throws IOException {
            // Read 2 header bytes
            int b0 = readRawByte();
            int b1 = readRawByte();
            // boolean fin = (b0 & 0x80) != 0;
            int opcode = b0 & 0x0f;
            boolean masked = (b1 & 0x80) != 0;
            long payloadLen = b1 & 0x7f;

            if (payloadLen == 126) {
                payloadLen = ((readRawByte() & 0xff) << 8) | (readRawByte() & 0xff);
            } else if (payloadLen == 127) {
                payloadLen = 0;
                for (int i = 0; i < 8; i++) payloadLen = (payloadLen << 8) | (readRawByte() & 0xff);
            }

            byte[] mask = null;
            if (masked) {
                mask = new byte[4];
                for (int i = 0; i < 4; i++) mask[i] = (byte) readRawByte();
            }

            if (opcode == 8) { // Close frame
                throw new IOException("WS: server closed connection");
            }
            if (opcode == 9) { // Ping — send Pong
                byte[] pingData = readRawBytes((int) payloadLen, mask);
                // can't send pong here easily without ref to wsOut; just discard
                payload = new byte[0]; payloadPos = 0;
                return;
            }
            if (opcode == 10) { // Pong — ignore
                readRawBytes((int) payloadLen, mask);
                payload = new byte[0]; payloadPos = 0;
                return;
            }
            // opcode 1 (text) or 2 (binary) — read payload
            payload = readRawBytes((int) payloadLen, mask);
            payloadPos = 0;
        }

        private byte[] readRawBytes(int len, byte[] mask) throws IOException {
            byte[] buf = new byte[len];
            int read = 0;
            while (read < len) {
                int n = raw.read(buf, read, len - read);
                if (n < 0) throw new IOException("WS stream closed");
                read += n;
            }
            if (mask != null) {
                for (int i = 0; i < len; i++) buf[i] ^= mask[i & 3];
            }
            return buf;
        }

        private int readRawByte() throws IOException {
            int b = raw.read();
            if (b < 0) throw new IOException("WS stream closed");
            return b;
        }
    }

    // ====================================================================
    // WebSocket frame encoder — wraps raw OutputStream
    // Sends client→server binary frames (masked, opcode=2)
    // ====================================================================
    private static final class WsOutputStream extends OutputStream {
        private final OutputStream raw;
        private final ByteArrayOutputStream buf = new ByteArrayOutputStream(4096);

        WsOutputStream(OutputStream raw) { this.raw = raw; }

        @Override
        public void write(int b) throws IOException { buf.write(b); }

        @Override
        public void write(byte[] b, int off, int len) throws IOException {
            buf.write(b, off, len);
        }

        @Override
        public void flush() throws IOException {
            if (buf.size() == 0) return;
            byte[] data = buf.toByteArray();
            buf.reset();
            sendFrame(2, data); // opcode 2 = binary
        }

        void sendClose() throws IOException {
            sendFrame(8, new byte[0]); // opcode 8 = close
        }

        private void sendFrame(int opcode, byte[] data) throws IOException {
            int len = data.length;
            // Generate 4-byte mask
            byte[] mask = new byte[4];
            new Random().nextBytes(mask);

            // Header
            byte b0 = (byte)(0x80 | (opcode & 0x0f)); // FIN + opcode
            raw.write(b0);
            if (len < 126) {
                raw.write(0x80 | len);  // MASK bit + len
            } else if (len < 65536) {
                raw.write(0x80 | 126);
                raw.write((len >> 8) & 0xff);
                raw.write(len & 0xff);
            } else {
                raw.write(0x80 | 127);
                for (int i = 7; i >= 0; i--) raw.write((len >> (i*8)) & 0xff);
            }
            raw.write(mask);
            // Masked payload
            for (int i = 0; i < len; i++) {
                raw.write(data[i] ^ mask[i & 3]);
            }
            raw.flush();
        }
    }
}
