.PHONY: help scenarios prepare prepare-gpu build build-gpu up up-gpu up-multi-isp up-multi-isp-gpu gpu-check down status check profile-fiber profile-5g profile-4g profile-dsl profile-congested profile-3g profile-bad traffic-off traffic-light traffic-medium traffic-heavy clean-media

help:
	@./labctl.sh help

scenarios:
	@./labctl.sh scenarios

prepare:
	@./labctl.sh prepare cpu

prepare-gpu:
	@./labctl.sh prepare gpu

build:
	@./labctl.sh build cpu

build-gpu:
	@./labctl.sh build gpu

up:
	@./labctl.sh up cpu

up-gpu:
	@./labctl.sh up gpu

up-multi-isp:
	@./labctl.sh up multi-isp cpu

up-multi-isp-gpu:
	@./labctl.sh up multi-isp gpu

gpu-check:
	@./labctl.sh gpu-check

down:
	@./labctl.sh down

status:
	@./labctl.sh status

check:
	@./labctl.sh check

profile-fiber profile-5g profile-4g profile-dsl profile-congested profile-3g profile-bad:
	@./labctl.sh profile $(@:profile-%=%)

traffic-off traffic-light traffic-medium traffic-heavy:
	@./labctl.sh traffic $(@:traffic-%=%)

clean-media:
	@./labctl.sh clean-media
