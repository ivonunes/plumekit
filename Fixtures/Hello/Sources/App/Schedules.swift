import PlumeCore

// Scheduled tasks, declared in one place (like Routes). `buildSchedule()` is generated
// and calls this; the schedule's tick is delivered as a job (see the generated buildJobs).
//
//   schedule.task("daily-digest", every: .daily(hour: 6)) { context in
//       try await SomeJob(...).enqueue(on: context.queue)   // a discovered job
//   }
func registerSchedules(_ schedule: inout Schedule) {
    // no scheduled tasks in this example
}
