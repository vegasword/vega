package vega

import "base:intrinsics"
import "core:fmt"
import "core:log"
import "core:strings"
import "core:thread"

Shell_Job :: struct {
	command:   string,
	output:    string,
	exit_code: u32,
	ok:        bool,
	finished:  bool,
	worker:    ^thread.Thread,
}

shell_job: ^Shell_Job

shell_worker :: proc(worker: ^thread.Thread) {
	job := (^Shell_Job)(worker.data)
	output, exit_code, ok := run_hidden(strings.concatenate({shell_prefix(), job.command}, context.temp_allocator))
	job.output = output
	job.exit_code = exit_code
	job.ok = ok
	intrinsics.atomic_store(&job.finished, true)
}

shell_run :: proc(editor: ^Editor, command_line: string) {
	if shell_job != nil {
		notify(fmt.tprintf("%s is still running", shell_job.command), .Warning)
		return
	}
	log.infof("running shell command: %s", command_line)
	job := new(Shell_Job)
	job.command = strings.clone(command_line)
	job.worker = thread.create(shell_worker)
	if job.worker == nil {
		delete(job.command)
		free(job)
		notify(fmt.tprintf("Could not start: %s", command_line), .Error)
		return
	}
	job.worker.data = job
	shell_job = job
	thread.start(job.worker)
}

shell_poll :: proc(editor: ^Editor) {
	job := shell_job
	if job == nil || !intrinsics.atomic_load(&job.finished) {
		return
	}
	thread.join(job.worker)
	thread.destroy(job.worker)
	shell_job = nil

	if !job.ok {
		notify(fmt.tprintf("Could not run: %s", job.command), .Error)
	} else if diagnostics_collect(editor, job.output); len(editor.diagnostics) > 0 {
		editor.diagnostic_cursor = -1
		diagnostic_go(editor, 1)
		log.infof("output of %s:\n%s", job.command, job.output)
	} else {
		title := job.exit_code == 0 ? fmt.tprintf("%s ok", job.command) : fmt.tprintf("%s failed with %d", job.command, job.exit_code)
		output_show(editor, title, job.output, job.exit_code != 0)
		log.infof("output of %s:\n%s", job.command, job.output)
	}
	delete(job.output)
	delete(job.command)
	free(job)
}
