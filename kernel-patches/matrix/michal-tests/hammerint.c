#include <stdio.h>
#include <stdlib.h>

#include <libusb-1.0/libusb.h>

void comp(struct libusb_transfer *t) {
	char c = t->status == LIBUSB_TRANSFER_CANCELLED ? '.' :
		t->status == LIBUSB_TRANSFER_COMPLETED ? ',' : '-';
	fputc(c, stdout);
	fflush(stdout);
}

int hammer(int vid, int pid, int ifc, int ep) {
	struct libusb_device_handle *d;
	struct libusb_transfer *t;
	char bufi[1024] = {0};
	char bufc[2];
	int r;

	r = libusb_init(NULL);
	t = libusb_alloc_transfer(0);
	if (r || !t)
		return 1;

	d = libusb_open_device_with_vid_pid(NULL, vid, pid);
	if (!d)
		return 2;

	libusb_detach_kernel_driver(d, ifc);
	r = libusb_claim_interface(d, ifc);
	if (r)
		return 3;

	libusb_fill_interrupt_transfer(t, d, ep, bufi, sizeof(bufi), comp, NULL, 0);

	for (;;) {
		/* GET_STATUS(DEVICE) */
		r = libusb_control_transfer(d, 0x80, 0, 0, 0, bufc, sizeof(bufc), 100);
		if (r != sizeof(bufc))
			return 4;

		r = libusb_submit_transfer(t);
		if (r)
			return 5;
		r = libusb_cancel_transfer(t);
		if (r)
			return 6;
		r = libusb_handle_events(NULL);
		if (r)
			return 7;
	}
}

int main (int argc, char **argv) {
	int vid, pid, ifc, ep;
	int r;

	if (argc != 5) {
		fprintf(stderr, "USAGE: %s vid pid ifc ep\n", argv[0]);
		return 1;
	}

	vid = strtol(argv[1], NULL, 16);
	pid = strtol(argv[2], NULL, 16);
	ifc = strtol(argv[3], NULL, 16);
	ep = strtol(argv[4], NULL, 16);

	r = hammer(vid, pid, ifc, ep);
	printf("%d\n", r);
}
