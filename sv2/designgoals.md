https://github.com/stratum-mining/sv2-spec/blob/main/02-Design-Goals.md
- Precisely defined binary protocol
- Drop JSON
- First class [BIP-0320](https://github.com/bitcoin/bips/blob/master/bip-0320.mediawiki) aka "version rolling", aka AsicBoost, aka etc. -- Using 16 bits of `nVersion` field of a block header as an additional nonce element, both because it expands available values, and alllows you to reuse a little bit of sha256 midstate (Don't fully understand this: see https://arxiv.org/pdf/1604.00575)
- Header-only mining
- Lower bandwidth use, lower latency.
- Wherever possible, put complexity on the poolside, firmware updates are
  infrequent, difficult, expensive, risky, etc. etc.
- Some backward/forwards compatibility with SV1
