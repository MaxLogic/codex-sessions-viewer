//! Opt-in debug/test completeness check, independent of SQL call-site inventory.
//! Install before configure/bootstrap. Hooks never reject or alter SQL; inspect
//! the report after the exercised operations have finished. Connections keep
//! their hooks across moves. This replaces existing commit/authorizer hooks,
//! so use only on connections dedicated to the audit (not failure-injection hooks).
use super::{ACTIVE, connection_key};
use rusqlite::{
    Connection,
    hooks::{AuthAction, AuthContext, Authorization},
};
use std::{
    cell::RefCell,
    collections::HashMap,
    sync::{Arc, Mutex, Weak},
};

#[derive(Clone, Debug, Default)]
pub struct AuditReport {
    pub connections: u64,
    pub commits: u64,
    pub completed_holds: u64,
    pub unattributed: Vec<String>,
    pending: HashMap<usize, u64>,
}
impl AuditReport {
    pub fn assert_complete(&self) {
        assert!(
            self.unattributed.is_empty(),
            "unattributed SQLite writes: {:?}",
            self.unattributed
        );
        assert!(
            self.pending.is_empty(),
            "SQLite commits without completed hold samples: {:?}",
            self.pending
        );
    }
}
type State = Arc<Mutex<AuditReport>>;
thread_local! {
    static CAPTURE: RefCell<Option<State>> = const { RefCell::new(None) };
    static CONNECTIONS: RefCell<HashMap<usize, Weak<Mutex<AuditReport>>>> = RefCell::default();
}

/// Automatically audit collector connections configured on this worker thread.
/// Not inherited by other threads or processes; those need their own scope.
pub struct WriteAudit {
    state: State,
    previous: Option<State>,
    _thread: std::marker::PhantomData<std::rc::Rc<()>>,
}
impl Default for WriteAudit {
    fn default() -> Self {
        Self::start()
    }
}
impl WriteAudit {
    pub fn start() -> Self {
        let state = Arc::new(Mutex::new(AuditReport::default()));
        let previous = CAPTURE.with_borrow_mut(|current| current.replace(state.clone()));
        Self {
            state,
            previous,
            _thread: std::marker::PhantomData,
        }
    }
    pub fn report(&self) -> AuditReport {
        self.state.lock().unwrap().clone()
    }
    pub fn assert_complete(&self) {
        self.report().assert_complete();
    }
    pub fn attach(&self, conn: &Connection) -> rusqlite::Result<()> {
        attach(conn, self.state.clone())
    }
}
impl Drop for WriteAudit {
    fn drop(&mut self) {
        CAPTURE.with_borrow_mut(|current| *current = self.previous.take());
        CONNECTIONS
            .with_borrow_mut(|connections| connections.retain(|_, state| state.strong_count() > 0));
    }
}
pub(crate) fn configured(conn: &Connection) -> rusqlite::Result<()> {
    if let Some(state) = CAPTURE.with_borrow(Clone::clone) {
        attach(conn, state)?;
    }
    Ok(())
}
fn owned(key: usize) -> bool {
    ACTIVE.with_borrow(|active| active.contains_key(&key))
}
/// A new sample must never discharge an older owner's commit receipt. Keep
/// this failure sticky even if the replacement completes on the same connection.
/// Only debug audit state changes; release transaction behavior is unchanged.
pub(super) fn check_replaced_owner(conn: &Connection) {
    let key = connection_key(conn);
    if owned(key) {
        CONNECTIONS.with_borrow(|connections| {
            if let Some(state) = connections.get(&key).and_then(Weak::upgrade) {
                state
                    .lock()
                    .unwrap()
                    .unattributed
                    .push("unfinished write owner replaced before completion".into());
            }
        });
    }
}
fn attach(conn: &Connection, state: State) -> rusqlite::Result<()> {
    let key = connection_key(conn);
    CONNECTIONS.with_borrow_mut(|connections| {
        connections.insert(key, Arc::downgrade(&state));
    });
    state.lock().unwrap().connections += 1;
    let commits = state.clone();
    conn.commit_hook(Some(move || {
        let mut report = commits.lock().unwrap();
        report.commits += 1;
        if owned(key) {
            *report.pending.entry(key).or_default() += 1;
        } else {
            report.unattributed.push("commit".into());
        }
        false
    }))?;
    conn.authorizer(Some(move |context: AuthContext<'_>| {
        // Journal-mode changes can update header bytes without invoking the
        // commit hook. Check persistent/maintenance pragmas independently.
        // This checks preparation; do not cache such statements across owners.
        if let AuthAction::Pragma {
            pragma_name,
            pragma_value,
        } = context.action
        {
            let name = pragma_name.to_ascii_lowercase();
            let writes = match name.as_str() {
                "journal_mode" | "user_version" | "application_id" | "auto_vacuum" => {
                    pragma_value.is_some()
                }
                "incremental_vacuum" | "wal_checkpoint" | "optimize" => true,
                _ => false,
            };
            if writes && !owned(key) {
                state
                    .lock()
                    .unwrap()
                    .unattributed
                    .push(format!("pragma {name}"));
            }
        }
        Authorization::Allow
    }))
}
pub(super) fn completed(conn: &Connection) {
    CONNECTIONS.with_borrow(|connections| {
        if let Some(state) = connections
            .get(&connection_key(conn))
            .and_then(Weak::upgrade)
        {
            let mut report = state.lock().unwrap();
            report.completed_holds += 1;
            if report
                .pending
                .remove(&connection_key(conn))
                .is_some_and(|commits| commits > 1)
            {
                report
                    .unattributed
                    .push("multiple commits for one hold sample".into());
            }
        }
    });
}
