# `CConnman::PushMessage()`

## `V.Transport::GetBytesToSend()`

This virtual function is part of the transport interface, it has a V1
implementation and a V2 implementation.

`GetBytesToSend()` is used to get the next bytes to send for a given transport
object. In `CConnman::PushMessage()`, it is
[used](https://github.com/bitcoin/bitcoin/blob/2d6a0c464912c325faf35d4ad28b1990e828b414/src/net.cpp#L3895-L3896)
to find out whether there any bytes queued for sending in the transport.

Its return value is defined as follows:

```cpp
/** Return type for GetBytesToSend, consisting of:
 *  - std::span<const uint8_t> to_send: span of bytes to be sent over the wire (possibly empty).
 *  - bool more: whether there will be more bytes to be sent after the ones in to_send are
 *    all sent (as signaled by MarkBytesSent()).
 *  - const std::string& m_type: message type on behalf of which this is being sent
 *    ("" for bytes that are not on behalf of any message).
 */
using BytesToSend = std::tuple<
    std::span<const uint8_t> /*to_send*/,
    bool /*more*/,
    const std::string& /*m_type*/
>;
```


### V1Transport

```cpp
Transport::BytesToSend V1Transport::GetBytesToSend(bool have_next_message) const noexcept
{
    // [ Take a lock on sending. ]
    AssertLockNotHeld(m_send_mutex);
    LOCK(m_send_mutex);

    // [ If the next thing to send is a message header. ]
    if (m_sending_header) {

        return {
                // [ The actual bytes to send, starting at the `m_bytes_sent`
                //   position indicator. ]
                std::span{m_header_to_send}.subspan(m_bytes_sent),
                // [ As far as I know, this should always be true, we don't
                //   send headers that don't have payloads. ]
                // We have more to send after the header if the message has payload, or if there
                // is a next message after that.
                have_next_message || !m_message_to_send.data.empty(),
                m_message_to_send.m_type
               };
    } else {
        return {
                // [ Message to send starting at the bytes sent index. ]
                std::span{m_message_to_send.data}.subspan(m_bytes_sent),
                // [ We are relying on the passed value. ]
                // We only have more to send after this message's payload if there is another
                // message.
                have_next_message,
                m_message_to_send.m_type
               };
    }
}
```

### V2Transport

```cpp
Transport::BytesToSend V2Transport::GetBytesToSend(bool have_next_message) const noexcept
{
    // [ Take a lock on sending. ]
    AssertLockNotHeld(m_send_mutex);
    LOCK(m_send_mutex);

    // [ If v1, then v1. ]
    if (m_send_state == SendState::V1) return m_v1_fallback.GetBytesToSend(have_next_message);

    // [ This state I asumme is only possible during the handshake. ]
    if (m_send_state == SendState::MAYBE_V1) Assume(m_send_buffer.empty());
    Assume(m_send_pos <= m_send_buffer.size());
    return {
        // [ Unlike in v1, there is no "header_to_send", just the send buffer. ]
        std::span{m_send_buffer}.subspan(m_send_pos),
        // We only have more to send after the current m_send_buffer if there is a (next)
        // message to be sent, and we're capable of sending packets. */
        have_next_message && m_send_state == SendState::READY,
        m_send_type
    };
}
```
