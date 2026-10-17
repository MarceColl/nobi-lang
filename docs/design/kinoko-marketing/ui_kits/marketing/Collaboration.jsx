import React from 'react';
import { WindowChrome } from '../../components/surfaces/WindowChrome.jsx';
import { Callout } from '../../components/surfaces/Callout.jsx';
import { TraceChip } from '../../components/console/TraceChip.jsx';
import { Tag } from '../../components/core/Tag.jsx';
import { SectionHead } from './SectionHead.jsx';

export function Presence() {
  const people = [['Agent', '#7DD3C0'], ['You', '#B8A5D9'], ['Sarah', '#F5C869']];
  return (
    <React.Fragment>
      {people.map(([name, color]) => (
        <span key={name} style={{ color, display: 'flex', alignItems: 'center', gap: 4 }}>
          <span style={{ width: 8, height: 8, borderRadius: '50%', background: color }} />
          {name}
        </span>
      ))}
    </React.Fragment>
  );
}

export function Comment({ who, color, initial, time, last, children }) {
  return (
    <div style={{ marginBottom: last ? 0 : 16 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 8 }}>
        <span style={{
          width: 24, height: 24, borderRadius: '50%', background: color,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          fontSize: 11, fontWeight: 600, color: 'var(--kn-void)',
        }}>{initial}</span>
        <span style={{ fontSize: 12, color }}>{who}</span>
        <span style={{ fontSize: 11, color: 'var(--kn-text-faint)' }}>{time}</span>
      </div>
      <div style={{ fontSize: 13, color: 'var(--kn-text-muted)', lineHeight: 1.5 }}>{children}</div>
    </div>
  );
}

export function Collaboration() {
  const [trace, setTrace] = React.useState(false);
  const [bugOpen, setBugOpen] = React.useState(false);

  const md = { color: 'var(--kn-text-dim)', marginBottom: 16 };
  const body = { color: 'var(--kn-text-muted)', marginBottom: 16 };

  return (
    <section style={{ position: 'relative', padding: '96px 32px' }}>
      <div style={{ maxWidth: 'var(--measure)', margin: '0 auto' }}>
        <SectionHead title="Collaborate with agents and your team">
          RFCs, design docs, and debugging sessions—all collaborative. Everything in the system is cross-referenceable: link traces to discussions, bugs to code, decisions to context. Agents and humans share the same address space.
        </SectionHead>

        <WindowChrome dense title="RFC: User Authentication System" right={<Presence />} style={{ boxShadow: 'var(--glow-violet-faint)' }}>
          <div className="rfc-container" style={{ display: 'flex' }}>
            <div style={{ flex: 1, padding: '24px 32px', fontFamily: 'var(--font-mono)', fontSize: 'var(--text-code)', lineHeight: 'var(--leading-code)' }}>
              <div style={md}>## Problem</div>
              <div style={body}>
                Users currently have no way to persist their sessions across
                <span style={{ borderLeft: '2px solid var(--kn-lilac)', marginLeft: 2, animation: 'kn-blink 1s infinite' }} />
                {' '}devices. This leads to frustration when switching between mobile and desktop.
              </div>

              <div style={md}>## Proposal</div>
              <div style={{ color: 'var(--kn-text-muted)', marginBottom: 8 }}>Implement a session management system with:</div>
              <div style={{ color: 'var(--kn-text-muted)', paddingLeft: 16, marginBottom: 8 }}>• JWT tokens with refresh token rotation</div>
              <div style={{ color: 'var(--kn-text-muted)', paddingLeft: 16, marginBottom: 8, position: 'relative' }}>
                • Session storage in the managed KV store
                <span style={{
                  position: 'absolute', right: -20, top: -2, width: 16, height: 16, borderRadius: '50%',
                  background: 'var(--kn-mint)', display: 'flex', alignItems: 'center', justifyContent: 'center',
                  fontSize: 9, color: 'var(--kn-void)', fontWeight: 600,
                }}>A</span>
              </div>
              <div style={{
                color: 'var(--kn-mint)', paddingLeft: 16, marginBottom: 8,
                background: 'rgba(125,211,192,0.1)', marginLeft: -8,
                paddingTop: 4, paddingBottom: 4, borderRadius: 'var(--radius-xs)',
              }}>
                • Device fingerprinting for suspicious login detection
                <span style={{ color: 'var(--kn-text-faint)', fontStyle: 'italic' }}> (just added)</span>
              </div>
              <div style={{ color: 'var(--kn-text-muted)', paddingLeft: 16, marginBottom: 16 }}>
                • Configurable session TTL per user role{' '}
                <span style={{ position: 'relative', display: 'inline-block' }}
                  onMouseEnter={() => setTrace(true)} onMouseLeave={() => setTrace(false)}>
                  <TraceChip>trace 983jq03</TraceChip>
                  {trace && (
                    <div style={{
                      position: 'absolute', top: '100%', left: 0, marginTop: 8, width: 280, zIndex: 100,
                      background: 'var(--kn-void)', border: '1px solid rgba(159,237,215,0.3)',
                      borderRadius: 'var(--radius-md)', padding: 12, boxShadow: 'var(--shadow-tooltip)',
                      lineHeight: 1.6,
                    }}>
                      <div style={{ color: 'var(--kn-text-dim)', marginBottom: 8, fontSize: 10, fontWeight: 600 }}>Function Trace — get_session_ttl()</div>
                      <div style={{ fontSize: 11 }}>
                        <div style={{ color: 'var(--kn-text-faint)', marginBottom: 4 }}>▸ Input</div>
                        <div style={{ paddingLeft: 8, marginBottom: 8 }}>
                          <span style={{ color: 'var(--kn-lilac)' }}>user_role:</span>
                          <span style={{ color: 'var(--kn-mint-light)' }}> "admin"</span>
                        </div>
                        <div style={{ color: 'var(--kn-text-faint)', marginBottom: 4 }}>▸ Execution</div>
                        <div style={{ paddingLeft: 8, marginBottom: 8, color: 'var(--kn-text-muted)' }}>
                          <div>→ lookup_role_config <span style={{ color: 'var(--kn-text-faint)' }}>2.1ms</span></div>
                          <div style={{ paddingLeft: 12 }}>→ cache_hit <span style={{ color: 'var(--kn-mint)' }}>✓</span></div>
                          <div>→ apply_overrides <span style={{ color: 'var(--kn-text-faint)' }}>0.3ms</span></div>
                        </div>
                        <div style={{ color: 'var(--kn-text-faint)', marginBottom: 4 }}>▸ Output</div>
                        <div style={{ paddingLeft: 8 }}>
                          <span style={{ color: 'var(--kn-lilac)' }}>ttl:</span>
                          <span style={{ color: 'var(--kn-amber)' }}> 86400</span>
                          <span style={{ color: 'var(--kn-text-faint)' }}> (24h)</span>
                        </div>
                      </div>
                    </div>
                  )}
                </span>
              </div>

              <div style={md}>## Open Questions</div>
              <Callout hue="amber" style={{ marginBottom: 16 }}>
                Should we support "remember me" functionality? — Sarah
              </Callout>

              <div style={md}>## Related Bug</div>
              <div
                onClick={() => setBugOpen(!bugOpen)}
                style={{
                  background: bugOpen ? 'rgba(255,107,107,0.12)' : 'rgba(255,107,107,0.08)',
                  border: '1px solid rgba(255,107,107,0.3)',
                  borderRadius: 'var(--radius-md)',
                  padding: '12px 14px', cursor: 'pointer',
                  transition: 'all var(--dur-fast) var(--ease)',
                }}
              >
                <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: bugOpen ? 12 : 0 }}>
                  <span style={{
                    width: 20, height: 20, borderRadius: 'var(--radius-xs)',
                    background: 'rgba(255,107,107,0.2)', display: 'flex',
                    alignItems: 'center', justifyContent: 'center',
                    fontSize: 12, color: 'var(--kn-red)', fontWeight: 700,
                  }}>!</span>
                  <div style={{ flex: 1 }}>
                    <div style={{ color: 'var(--kn-red)', fontSize: 12, fontWeight: 600 }}>BUG-1247: Session expires during checkout</div>
                    <div style={{ color: 'var(--kn-cap-shade)', fontSize: 11 }}>Click to replay debugging session</div>
                  </div>
                  <div style={{
                    color: 'var(--kn-text-faint)', fontSize: 16,
                    transform: bugOpen ? 'rotate(180deg)' : 'rotate(0deg)',
                    transition: 'transform var(--dur-fast) var(--ease)',
                  }}>▼</div>
                </div>

                {bugOpen && (
                  <div style={{ background: 'var(--kn-void)', borderRadius: 'var(--radius-sm)', padding: 12, fontSize: 11 }}>
                    <div style={{ color: 'var(--kn-text-dim)', marginBottom: 8, fontWeight: 600 }}>Request Replay — captured 3h ago</div>

                    <div style={{ marginBottom: 12 }}>
                      <div style={{ color: 'var(--kn-text-faint)', marginBottom: 4 }}>▸ Request</div>
                      <div style={{ paddingLeft: 12, color: 'var(--kn-text-muted)' }}>
                        <div><span style={{ color: 'var(--kn-mint)' }}>POST</span> /api/checkout</div>
                        <div style={{ color: 'var(--kn-text-faint)' }}>user_id: "usr_a1b2c3"</div>
                        <div style={{ color: 'var(--kn-text-faint)' }}>session: "sess_x9y8z7"</div>
                      </div>
                    </div>

                    <div style={{ marginBottom: 12 }}>
                      <div style={{ color: 'var(--kn-text-faint)', marginBottom: 4 }}>▸ State at failure</div>
                      <div style={{ paddingLeft: 12 }}>
                        <div style={{ color: 'var(--kn-amber)' }}>session.expires_at: 1706547200</div>
                        <div style={{ color: 'var(--kn-amber)' }}>current_time: 1706547205</div>
                        <div style={{ color: 'var(--kn-red)' }}>⚠ Session expired 5s before request</div>
                      </div>
                    </div>

                    <div style={{ marginBottom: 12 }}>
                      <div style={{ color: 'var(--kn-text-faint)', marginBottom: 4 }}>▸ Stack trace</div>
                      <div style={{ paddingLeft: 12, color: 'var(--kn-text-muted)' }}>
                        <div>at validate_session <span style={{ color: 'var(--kn-text-faint)' }}>auth.rs:142</span></div>
                        <div>at checkout_handler <span style={{ color: 'var(--kn-text-faint)' }}>checkout.rs:58</span></div>
                        <div>at router <span style={{ color: 'var(--kn-text-faint)' }}>main.rs:203</span></div>
                      </div>
                    </div>

                    <div style={{ display: 'flex', gap: 8, paddingTop: 8, borderTop: '1px solid rgba(42,37,56,0.5)' }}>
                      <Tag hue="mint" size="xs" style={{ padding: '4px 10px', fontWeight: 500, borderRadius: 'var(--radius-xs)' }}>Replay in sandbox</Tag>
                      <Tag hue="lilac" size="xs" style={{ padding: '4px 10px', fontWeight: 500, borderRadius: 'var(--radius-xs)' }}>View full context</Tag>
                    </div>
                  </div>
                )}
              </div>
            </div>

            <div className="rfc-comments" style={{
              width: 280, flexShrink: 0, padding: 16,
              borderLeft: '1px solid var(--kn-border)',
              background: 'rgba(26, 23, 37, 0.3)',
            }}>
              <div style={{ fontSize: 12, color: 'var(--kn-text-dim)', marginBottom: 16, fontWeight: 600 }}>
                Comments on "Session storage"
              </div>
              <Comment who="You" color="#B8A5D9" initial="Y" time="2m ago">
                Should we encrypt the session data at rest?
              </Comment>
              <Comment who="Agent" color="#7DD3C0" initial="A" time="1m ago">
                Yes, I'd recommend AES-256. The managed KV store supports transparent encryption—I can add that to the proposal.
              </Comment>
              <Comment who="Sarah" color="#F5C869" initial="S" time="just now" last>
                +1, let's do it. Also flagging the "remember me" question above ☝️
              </Comment>
              <div style={{
                marginTop: 16, padding: '10px 12px',
                background: 'rgba(42, 37, 56, 0.5)',
                borderRadius: 'var(--radius-md)',
                border: '1px solid var(--kn-border)',
              }}>
                <span style={{ fontSize: 12, color: 'var(--kn-text-faint)' }}>Reply...</span>
              </div>
            </div>
          </div>
        </WindowChrome>

        <div className="collab-features" style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(200px, 1fr))', gap: 16, marginTop: 32 }}>
          {[
            ['Real-time editing', 'Multiple cursors, live updates'],
            ['Threaded comments', 'Discuss inline, resolve together'],
            ['Embedded traces', 'Link any execution to any doc'],
            ['Shared address space', 'Humans and agents reference the same things'],
          ].map(([t, d]) => (
            <div key={t} style={{ textAlign: 'center', padding: 16 }}>
              <div style={{ fontFamily: 'var(--font-display)', fontSize: 15, fontWeight: 600, color: 'var(--kn-cream)', marginBottom: 4 }}>{t}</div>
              <div style={{ fontSize: 13, color: 'var(--kn-text-dim)' }}>{d}</div>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
