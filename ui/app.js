/* BashClaw Web Dashboard - Application Logic */

(function() {
  'use strict';

  // ---- State ----

  var state = {
    theme: localStorage.getItem('bashclaw-theme') || 'dark',
    tab: 'chat',
    models: [],
    aliases: {},
    providers: [],
    envStatus: [],
    channels: [],
    sessions: [],
    status: null,
    chatBusy: false,
    initialized: false
  };

  // ---- API ----

  var API = {
    base: window.location.origin,

    request: function(method, path, body) {
      var opts = {
        method: method,
        headers: { 'Content-Type': 'application/json' }
      };
      if (body) {
        opts.body = JSON.stringify(body);
      }
      return fetch(API.base + path, opts)
        .then(function(r) {
          if (!r.ok) {
            return r.json().then(function(e) { throw e; });
          }
          return r.json();
        });
    },

    getStatus: function() { return API.request('GET', '/api/status'); },
    getConfig: function() { return API.request('GET', '/api/config'); },
    setConfig: function(data) { return API.request('PUT', '/api/config', data); },
    getModels: function() { return API.request('GET', '/api/models'); },
    getSessions: function() { return API.request('GET', '/api/sessions'); },
    getChannels: function() { return API.request('GET', '/api/channels'); },
    getEnv: function() { return API.request('GET', '/api/env'); },
    setEnv: function(data) { return API.request('PUT', '/api/env', data); },
    chat: function(message) {
      return API.request('POST', '/api/chat', { message: message });
    },
    clearSession: function() {
      return API.request('POST', '/api/sessions/clear', {});
    }
  };

  // ---- DOM helpers ----

  function $(sel) { return document.querySelector(sel); }
  function $$(sel) { return document.querySelectorAll(sel); }

  function el(tag, attrs, children) {
    var e = document.createElement(tag);
    if (attrs) {
      Object.keys(attrs).forEach(function(k) {
        if (k === 'className') e.className = attrs[k];
        else if (k === 'textContent') e.textContent = attrs[k];
        else if (k === 'innerHTML') e.innerHTML = attrs[k];
        else if (k.indexOf('on') === 0) e.addEventListener(k.slice(2).toLowerCase(), attrs[k]);
        else e.setAttribute(k, attrs[k]);
      });
    }
    if (children) {
      (Array.isArray(children) ? children : [children]).forEach(function(c) {
        if (typeof c === 'string') e.appendChild(document.createTextNode(c));
        else if (c) e.appendChild(c);
      });
    }
    return e;
  }

  // ---- Theme ----

  function applyTheme(theme) {
    state.theme = theme;
    document.documentElement.setAttribute('data-theme', theme);
    localStorage.setItem('bashclaw-theme', theme);
    var icon = $('#theme-icon');
    if (icon) icon.textContent = theme === 'dark' ? '\u263D' : '\u2600';
  }

  // ---- Tab Routing ----

  function switchTab(tab) {
    state.tab = tab;
    $$('.nav-tab').forEach(function(t) {
      t.classList.toggle('active', t.getAttribute('data-tab') === tab);
    });
    $$('.panel').forEach(function(p) {
      p.classList.toggle('active', p.id === 'panel-' + tab);
    });
    if (tab === 'settings') loadSettings();
    if (tab === 'status') loadStatus();
  }

  // ---- Chat ----

  function addChatMessage(role, text) {
    var container = $('#chat-messages');
    var msg = el('div', { className: 'chat-msg ' + role });

    if (role === 'assistant') {
      msg.innerHTML = formatMarkdown(text);
    } else {
      msg.textContent = text;
    }

    container.appendChild(msg);
    container.scrollTop = container.scrollHeight;
    return msg;
  }

  function removeChatMessage(msgEl) {
    if (msgEl && msgEl.parentNode) {
      msgEl.parentNode.removeChild(msgEl);
    }
  }

  function formatMarkdown(text) {
    if (!text) return '';
    // Code blocks
    text = text.replace(/```(\w*)\n([\s\S]*?)```/g, function(_, lang, code) {
      return '<pre><code>' + escapeHtml(code.trim()) + '</code></pre>';
    });
    // Inline code
    text = text.replace(/`([^`]+)`/g, '<code>$1</code>');
    // Bold
    text = text.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
    // Italic
    text = text.replace(/\*(.+?)\*/g, '<em>$1</em>');
    return text;
  }

  function escapeHtml(s) {
    var div = document.createElement('div');
    div.textContent = s;
    return div.innerHTML;
  }

  function sendChat() {
    var input = $('#chat-input');
    var text = input.value.trim();
    if (!text || state.chatBusy) return;

    addChatMessage('user', text);
    input.value = '';
    input.style.height = 'auto';
    updateSendButton();

    state.chatBusy = true;
    setChatStatus('Thinking...');
    var thinkingMsg = addChatMessage('thinking', 'Thinking...');

    API.chat(text)
      .then(function(data) {
        removeChatMessage(thinkingMsg);
        if (data.response) {
          addChatMessage('assistant', data.response);
        }
        setChatStatus('');
      })
      .catch(function(err) {
        removeChatMessage(thinkingMsg);
        addChatMessage('system', 'Error: ' + (err.error || err.message || 'request failed'));
        setChatStatus('');
      })
      .finally(function() {
        state.chatBusy = false;
        updateSendButton();
      });
  }

  function clearChat() {
    API.clearSession()
      .then(function() {
        $('#chat-messages').innerHTML = '';
        addChatMessage('system', 'Session cleared');
      })
      .catch(function(err) {
        addChatMessage('system', 'Failed to clear: ' + (err.error || ''));
      });
  }

  function setChatStatus(text) {
    var el = $('#chat-status');
    if (el) el.textContent = text;
  }

  function updateSendButton() {
    var btn = $('#chat-send');
    var input = $('#chat-input');
    if (btn) btn.disabled = !input.value.trim() || state.chatBusy;
  }

  // ---- Settings ----

  function loadSettings() {
    Promise.all([API.getModels(), API.getEnv(), API.getChannels(), API.getConfig()])
      .then(function(results) {
        var modelsData = results[0];
        var envData = results[1];
        var channelsData = results[2];
        var configData = results[3];

        state.models = modelsData.models || [];
        state.aliases = modelsData.aliases || {};
        state.providers = modelsData.providers || [];
        state.envStatus = envData.env || [];
        state.channels = channelsData.channels || [];

        renderEnvList('#env-list', state.envStatus, false);
        renderModelSelect(configData);
        renderChannelsList();
      })
      .catch(function(err) {
        console.error('Failed to load settings:', err);
      });
  }

  function renderEnvList(selector, envItems, isOnboard) {
    var container = document.querySelector(selector);
    if (!container) return;
    container.innerHTML = '';

    envItems.forEach(function(item) {
      var row = el('div', { className: 'env-item' }, [
        el('span', { className: 'env-status ' + (item.is_set ? 'set' : 'unset') }),
        el('span', { className: 'env-provider', textContent: item.provider }),
        el('span', { className: 'env-var', textContent: item.env_var }),
        el('input', {
          type: 'password',
          placeholder: item.is_set ? '(configured)' : 'Enter API key...',
          'data-env': item.env_var,
          autocomplete: 'off'
        }),
        el('button', {
          className: 'btn btn-sm btn-save-key',
          textContent: 'Save',
          onClick: function() {
            var inp = row.querySelector('input');
            var val = inp.value.trim();
            if (!val) return;
            var payload = {};
            payload[item.env_var] = val;
            API.setEnv(payload)
              .then(function() {
                inp.value = '';
                inp.placeholder = '(configured)';
                var dot = row.querySelector('.env-status');
                if (dot) {
                  dot.className = 'env-status set';
                }
                item.is_set = true;
              })
              .catch(function(err) {
                alert('Failed to save: ' + (err.error || ''));
              });
          }
        })
      ]);
      container.appendChild(row);
    });
  }

  function renderModelSelect(config) {
    var select = $('#model-select');
    if (!select) return;
    select.innerHTML = '';

    var currentModel = '';
    if (config && config.agents && config.agents.defaults) {
      currentModel = config.agents.defaults.model || '';
    }

    // Group models by provider
    var byProvider = {};
    state.models.forEach(function(m) {
      var p = m.provider || 'other';
      if (!byProvider[p]) byProvider[p] = [];
      byProvider[p].push(m);
    });

    Object.keys(byProvider).sort().forEach(function(provider) {
      var group = el('optgroup', { label: provider });
      byProvider[provider].forEach(function(m) {
        var opt = el('option', {
          value: m.id,
          textContent: m.id
        });
        if (m.id === currentModel) opt.selected = true;
        group.appendChild(opt);
      });
      select.appendChild(group);
    });

    select.onchange = function() {
      var model = select.value;
      API.setConfig({
        agents: { defaults: { model: model } }
      }).then(function() {
        renderModelInfo(model);
      });
    };

    renderModelInfo(currentModel || (state.models[0] && state.models[0].id));
  }

  function renderModelInfo(modelId) {
    var container = $('#model-info');
    if (!container) return;
    container.innerHTML = '';

    var model = null;
    for (var i = 0; i < state.models.length; i++) {
      if (state.models[i].id === modelId) {
        model = state.models[i];
        break;
      }
    }
    if (!model) return;

    var fields = [
      { label: 'Provider', value: model.provider },
      { label: 'Max Tokens', value: (model.max_tokens || 0).toLocaleString() },
      { label: 'Context', value: (model.context_window || 0).toLocaleString() },
      { label: 'Input', value: (model.input || []).join(', ') || 'text' },
      { label: 'Reasoning', value: model.reasoning ? 'Yes' : 'No' }
    ];

    fields.forEach(function(f) {
      container.appendChild(
        el('div', { className: 'model-info-item' }, [
          el('div', { className: 'label', textContent: f.label }),
          el('div', { className: 'value', textContent: f.value })
        ])
      );
    });
  }

  function renderChannelsList() {
    var container = $('#channels-list');
    if (!container) return;
    container.innerHTML = '';

    if (!state.channels.length) {
      container.appendChild(el('div', { className: 'empty-state', textContent: 'No channels installed' }));
      return;
    }

    state.channels.forEach(function(ch) {
      container.appendChild(
        el('div', { className: 'channel-item' }, [
          el('span', { className: 'channel-name', textContent: ch.name }),
          el('span', {
            className: 'channel-badge ' + (ch.enabled ? 'enabled' : 'disabled'),
            textContent: ch.enabled ? 'Enabled' : 'Disabled'
          })
        ])
      );
    });
  }

  // ---- Status ----

  function loadStatus() {
    Promise.all([API.getStatus(), API.getSessions()])
      .then(function(results) {
        state.status = results[0];
        state.sessions = (results[1] && results[1].sessions) || [];
        renderStatus();
        renderSessions();
      })
      .catch(function(err) {
        console.error('Failed to load status:', err);
      });
  }

  function renderStatus() {
    var container = $('#status-system');
    if (!container || !state.status) return;
    container.innerHTML = '';

    var s = state.status;
    var cards = [
      { label: 'Status', value: s.status || 'unknown', cls: s.status === 'ok' ? 'ok' : 'error' },
      { label: 'Version', value: s.version || '-' },
      { label: 'Model', value: s.model || '-' },
      { label: 'Provider', value: s.provider || '-' },
      { label: 'Sessions', value: String(s.sessions || 0) },
      { label: 'Gateway', value: (s.gateway && s.gateway.running) ? 'Running' : 'Stopped',
        cls: (s.gateway && s.gateway.running) ? 'ok' : 'warn' }
    ];

    cards.forEach(function(c) {
      container.appendChild(
        el('div', { className: 'status-card' }, [
          el('div', { className: 'label', textContent: c.label }),
          el('div', { className: 'value' + (c.cls ? ' ' + c.cls : ''), textContent: c.value })
        ])
      );
    });
  }

  function renderSessions() {
    var container = $('#status-sessions');
    if (!container) return;
    container.innerHTML = '';

    if (!state.sessions.length) {
      container.appendChild(el('div', { className: 'empty-state', textContent: 'No active sessions' }));
      return;
    }

    state.sessions.forEach(function(s) {
      var sizeStr = s.size > 1024 ? (s.size / 1024).toFixed(1) + ' KB' : s.size + ' B';
      container.appendChild(
        el('div', { className: 'session-item' }, [
          el('span', { className: 'session-name', textContent: s.name }),
          el('span', { className: 'session-meta', textContent: s.messages + ' msgs / ' + sizeStr })
        ])
      );
    });
  }

  // ---- Onboarding ----

  function checkFirstRun() {
    API.getEnv()
      .then(function(data) {
        var envItems = data.env || [];
        // Filter to main providers only
        var mainProviders = envItems.filter(function(e) {
          return e.provider !== 'search';
        });
        var anySet = mainProviders.some(function(e) { return e.is_set; });
        if (!anySet) {
          showOnboarding(mainProviders);
        }
      })
      .catch(function() {
        // API not available, gateway might not be running
      });
  }

  function showOnboarding(envItems) {
    var overlay = $('#onboard-overlay');
    if (!overlay) return;
    overlay.classList.remove('hidden');

    renderEnvList('#onboard-keys', envItems, true);

    $('#onboard-skip').onclick = function() {
      overlay.classList.add('hidden');
    };

    $('#onboard-save').onclick = function() {
      // Collect all filled inputs
      var inputs = overlay.querySelectorAll('input[data-env]');
      var payload = {};
      var hasValue = false;
      inputs.forEach(function(inp) {
        var val = inp.value.trim();
        if (val) {
          payload[inp.getAttribute('data-env')] = val;
          hasValue = true;
        }
      });

      if (!hasValue) {
        overlay.classList.add('hidden');
        return;
      }

      API.setEnv(payload)
        .then(function() {
          overlay.classList.add('hidden');
          addChatMessage('system', 'API keys saved. You can start chatting.');
        })
        .catch(function(err) {
          alert('Failed to save keys: ' + (err.error || ''));
        });
    };
  }

  // ---- Init ----

  function init() {
    applyTheme(state.theme);

    // Theme toggle
    $('#theme-toggle').onclick = function() {
      applyTheme(state.theme === 'dark' ? 'light' : 'dark');
    };

    // Tab navigation
    $$('.nav-tab').forEach(function(tab) {
      tab.onclick = function() {
        switchTab(tab.getAttribute('data-tab'));
      };
    });

    // Chat input
    var chatInput = $('#chat-input');
    chatInput.addEventListener('input', function() {
      this.style.height = 'auto';
      this.style.height = Math.min(this.scrollHeight, 120) + 'px';
      updateSendButton();
    });

    chatInput.addEventListener('keydown', function(e) {
      if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        sendChat();
      }
    });

    $('#chat-send').onclick = sendChat;
    $('#chat-clear').onclick = clearChat;

    // Load version
    API.getStatus()
      .then(function(data) {
        var ver = $('#nav-version');
        if (ver && data.version) {
          ver.textContent = 'v' + data.version;
        }
        state.initialized = true;
      })
      .catch(function() {
        addChatMessage('system', 'Cannot connect to gateway. Is bashclaw gateway running?');
      });

    // First-run check
    checkFirstRun();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }

})();
