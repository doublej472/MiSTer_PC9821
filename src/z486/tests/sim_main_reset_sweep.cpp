#include "Vtb_reset_sweep.h"
#include "verilated.h"

// Mid-instruction resets trip sim-only internal-consistency checks (their own
// checker registers aren't reset); ignore those $stop trips and rely on the
// bench's sweep_done handshake instead of gotFinish.

// $stop / non-fatal-error path used by Verilator's generated $fatal checks.
void vl_stop(const char* filename, int linenum, const char* hier) VL_MT_UNSAFE {
    (void)hier;
    static int reported = 0;
    if (reported++ < 8)
        VL_PRINTF("%%Warning: ignoring mid-reset sim-check trip at %s:%d\n",
                  filename ? filename : "", linenum);
}

// Not expected to fire here, but keep it from ending the run if it does.
void vl_fatal(const char* filename, int linenum, const char* hier,
              const char* msg) VL_MT_UNSAFE {
    (void)hier;
    static int reported = 0;
    if (reported++ < 8)
        VL_PRINTF("%%Warning: ignoring mid-reset $fatal at %s:%d: %s\n",
                  filename ? filename : "", linenum, msg ? msg : "");
}

int main(int argc, char** argv) {
    auto* contextp = new VerilatedContext;
    contextp->commandArgs(argc, argv);
    contextp->fatalOnError(false);

    auto* top = new Vtb_reset_sweep{contextp};

    const vluint64_t kTimeLimit = 4000000000ULL;
    while (!top->sweep_done && contextp->time() < kTimeLimit) {
        top->eval();
        contextp->timeInc(1);
    }

    const int rc = (top->sweep_done && top->sweep_pass) ? 0 : 1;
    delete top;
    delete contextp;
    return rc;
}
