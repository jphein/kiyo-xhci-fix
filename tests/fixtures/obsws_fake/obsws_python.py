"""Fake obsws_python for tests/test-camera-scene.sh: an in-memory OBS with just what camera-scene uses.
State comes from / goes to the JSON file named by OBS_FAKE_STATE so the test can inspect it between runs."""
import json, os
from types import SimpleNamespace as NS

PATH = os.environ["OBS_FAKE_STATE"]


def _load():
    return json.load(open(PATH))


def _save(s):
    json.dump(s, open(PATH, "w"), indent=1)


class OBSSDKRequestError(Exception):
    pass


class ReqClient:
    def __init__(self, **kw):
        s = _load()
        if s.get("down"):
            raise ConnectionRefusedError("fake OBS down")
        s.setdefault("calls", []).append("connect")
        _save(s)

    def _do(self, name, fn):
        s = _load()
        s["calls"].append(name)
        out = fn(s)
        _save(s)
        return out

    # reads
    def get_video_settings(self):
        return self._do("get_video_settings", lambda s: NS(base_width=s["canvas"][0], base_height=s["canvas"][1]))

    def get_scene_list(self):
        return self._do("get_scene_list", lambda s: NS(scenes=[{"sceneName": n} for n in s["scenes"]]))

    def get_input_list(self):
        return self._do("get_input_list", lambda s: NS(inputs=[{"inputName": n} for n in s["inputs"]]))

    def get_input_settings(self, name):
        return self._do("get_input_settings", lambda s: NS(input_settings=dict(s["inputs"][name]["settings"])))

    def get_scene_item_list(self, scene):
        return self._do("get_scene_item_list", lambda s: NS(scene_items=[
            {"sourceName": it["source"], "sceneItemIndex": i} for i, it in enumerate(s["scenes"][scene])]))

    def get_scene_item_id(self, scene, source):
        def f(s):
            for i, it in enumerate(s["scenes"][scene]):
                if it["source"] == source:
                    return NS(scene_item_id=it["id"])
            raise OBSSDKRequestError(f"no {source} in {scene}")
        return self._do("get_scene_item_id", f)

    def get_scene_item_transform(self, scene, iid):
        return self._do("get_scene_item_transform", lambda s: NS(scene_item_transform=dict(
            next(it for it in s["scenes"][scene] if it["id"] == iid)["transform"])))

    def get_source_filter_list(self, src):
        return self._do("get_source_filter_list", lambda s: NS(filters=[
            {"filterName": n} for n in s["inputs"][src].get("filters", {})]))

    def get_source_filter(self, src, name):
        return self._do("get_source_filter", lambda s: NS(filter_settings=dict(s["inputs"][src]["filters"][name]["settings"])))

    def get_current_program_scene(self):
        return self._do("get_current_program_scene", lambda s: NS(current_program_scene_name=s["program"]))

    # writes
    def create_scene(self, name):
        self._do("create_scene", lambda s: s["scenes"].__setitem__(name, []))

    def _add_item(self, s, scene, source):
        s["next_id"] = s.get("next_id", 100) + 1
        s["scenes"][scene].append({"id": s["next_id"], "source": source, "transform": {}})

    def create_input(self, scene, name, kind, settings, enabled):
        def f(s):
            s["inputs"][name] = {"kind": kind, "settings": settings, "filters": {}}
            self._add_item(s, scene, name)
        self._do("create_input", f)

    def set_input_settings(self, name, settings, overlay):
        self._do("set_input_settings", lambda s: s["inputs"][name]["settings"].update(settings))

    def create_scene_item(self, scene, source, enabled):
        self._do("create_scene_item", lambda s: self._add_item(s, scene, source))

    def create_source_filter(self, src, name, kind, settings):
        self._do("create_source_filter", lambda s: s["inputs"][src]["filters"].__setitem__(
            name, {"kind": kind, "settings": settings}))

    def set_scene_item_transform(self, scene, iid, t):
        def f(s):
            if any(k in t for k in ("width", "height", "sourceWidth", "sourceHeight")):
                raise OBSSDKRequestError("read-only transform field sent")
            if t.get("boundsType") == "OBS_BOUNDS_NONE" and any(k in t for k in ("boundsWidth", "boundsHeight")):
                raise OBSSDKRequestError("boundsWidth less than 1")   # what real OBS answers to bounds 0
            next(it for it in s["scenes"][scene] if it["id"] == iid)["transform"] = dict(t)
        self._do("set_scene_item_transform", f)

    def set_scene_item_index(self, scene, iid, idx):
        def f(s):
            items = s["scenes"][scene]
            it = next(i for i in items if i["id"] == iid)
            items.remove(it)
            items.insert(idx, it)
        self._do("set_scene_item_index", f)

    def set_current_program_scene(self, name):
        self._do("set_current_program_scene", lambda s: s.__setitem__("program", name))
