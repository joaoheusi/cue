use crate::domain::*;
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    time::{Duration, Instant},
};
pub struct Invocation {
    pub target: Option<crate::platform::Target>,
    pub target_error: Option<Error>,
    pub id: String,
    pub created: Instant,
    pub consumed: bool,
    pub results: HashMap<String, Value>,
}
#[derive(Default)]
pub struct Engine {
    pub invocation: Option<Invocation>,
    library_results: HashMap<String, (Instant, String, Value)>,
}
impl Engine {
    pub fn prior_library(&mut self, key: &str, identity: &str) -> Result<Option<Value>> {
        self.library_results
            .retain(|_, (time, _, _)| time.elapsed() < Duration::from_secs(300));
        if let Some((_, previous_identity, result)) = self.library_results.get(key) {
            if previous_identity != identity {
                return Err(error(
                    "VALIDATION",
                    "An execution key cannot be reused for a different action.",
                ));
            }
            return Ok(Some(result.clone()));
        }
        if self.library_results.len() >= 1024 {
            return Err(error(
                "EXECUTION_BUSY",
                "Too many recent deliveries. Wait before copying another action.",
            ));
        }
        Ok(None)
    }
    pub fn finish_library(&mut self, key: &str, identity: String, result: Value) {
        self.library_results
            .insert(key.into(), (Instant::now(), identity, result));
    }
    pub fn begin(&mut self) -> String {
        let id = uuid::Uuid::new_v4().to_string();
        self.invocation = Some(Invocation {
            id: id.clone(),
            target: None,
            target_error: None,
            created: Instant::now(),
            consumed: false,
            results: HashMap::new(),
        });
        id
    }
    pub fn cancel(&mut self) {
        self.invocation = None;
    }
    pub fn prior(&self, id: &str, key: &str) -> Result<Option<Value>> {
        let i = self.invocation.as_ref().ok_or_else(|| {
            error(
                "INVOCATION_EXPIRED",
                "Reopen the palette to use this action.",
            )
        })?;
        if i.id != id || i.created.elapsed() > Duration::from_secs(300) {
            return Err(error(
                "INVOCATION_EXPIRED",
                "Reopen the palette to use this action.",
            ));
        }
        if let Some(result) = i.results.get(key) {
            return Ok(Some(result.clone()));
        }
        if i.consumed {
            return Err(error(
                "INVOCATION_EXPIRED",
                "This invocation has already been used.",
            ));
        }
        Ok(None)
    }
    pub fn claim(&mut self, id: &str) -> Result<()> {
        let i = self
            .invocation
            .as_mut()
            .ok_or_else(|| error("INVOCATION_EXPIRED", "Reopen the palette."))?;
        if i.id != id || i.consumed || i.created.elapsed() > Duration::from_secs(300) {
            return Err(error(
                "INVOCATION_EXPIRED",
                "This invocation has expired or been used.",
            ));
        }
        i.consumed = true;
        Ok(())
    }
    pub fn finish(&mut self, key: &str, result: Value) {
        if let Some(i) = &mut self.invocation {
            i.results.insert(key.into(), result);
        }
    }
}
pub fn copied(usage_saved: bool) -> Value {
    json!({"status":"copied","message":"Copied.","usageSaved":usage_saved})
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn failed_paste_cannot_be_delivered_twice() {
        let mut engine = Engine::default();
        let id = engine.begin();
        engine.claim(&id).unwrap();
        let failed = json!({"status":"copied_not_pasted"});
        engine.finish("request", failed.clone());
        assert_eq!(engine.prior(&id, "request").unwrap(), Some(failed));
        assert!(engine.prior(&id, "retry").is_err());
        assert!(engine.claim(&id).is_err());
    }
    #[test]
    fn one_delivery_per_invocation() {
        let mut e = Engine::default();
        let id = e.begin();
        assert!(e.prior(&id, "a").unwrap().is_none());
        e.claim(&id).unwrap();
        e.finish("a", copied(true));
        assert!(e.prior(&id, "a").unwrap().is_some());
        assert!(e.prior(&id, "b").is_err());
        assert!(e.claim(&id).is_err());
    }
    #[test]
    fn cancellation_and_expiry() {
        let mut e = Engine::default();
        let id = e.begin();
        e.cancel();
        assert!(e.prior(&id, "a").is_err());
        let id = e.begin();
        e.invocation.as_mut().unwrap().created = Instant::now() - Duration::from_secs(301);
        assert!(e.claim(&id).is_err());
    }
    #[test]
    fn library_idempotency_survives_new_invocations() {
        let mut e = Engine::default();
        e.begin();
        e.finish_library("key", "action:1".into(), copied(true));
        e.begin();
        assert!(e.prior_library("key", "action:1").unwrap().is_some());
        assert!(e.prior_library("key", "other:1").is_err());
    }
}
