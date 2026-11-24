#include "solver.hpp"
#include <chrono>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/godot.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
using namespace godot;
namespace bs = blacksmith;
namespace {
std::string text(const String &s) { return s.utf8().get_data(); }
bool numeric(const Variant &v) {
    return (v.get_type() == Variant::INT || v.get_type() == Variant::FLOAT) &&
           std::isfinite(double(v));
}
bool number(const Dictionary &d, const char *key, double &out) {
    Variant v = d.get(key, Variant());
    if (!numeric(v))
        return false;
    out = double(v);
    return true;
}
bs::V unpack(Vector3 v) { return {v.x, v.y, v.z}; }
Vector3 pack(bs::V v) { return {v.x, v.y, v.z}; }
bs::B unpack(Basis b) {
    return {unpack(b.get_column(0)), unpack(b.get_column(1)), unpack(b.get_column(2))};
}
Basis pack(bs::B b) { return {pack(b.x), pack(b.y), pack(b.z)}; }
bool vector_field(const Dictionary &d, const char *key, bs::V &out) {
    Variant v = d.get(key, Variant());
    if (v.get_type() != Variant::VECTOR3)
        return false;
    out = unpack(Vector3(v));
    return out.finite();
}
bool basis_field(const Dictionary &d, const char *key, bs::B &out) {
    Variant v = d.get(key, Variant());
    if (v.get_type() != Variant::BASIS)
        return false;
    out = unpack(Basis(v));
    return out.finite() && out.determinant() > 0;
}
bool index_field(const Dictionary &d, const char *key, int &out) {
    double value;
    if (!number(d, key, value) || value != std::floor(value) || value < 0 ||
        value > std::numeric_limits<int>::max())
        return false;
    out = int(value);
    return true;
}
bool values(const Variant &v, std::vector<double> &out, bool &vector) {
    vector = v.get_type() == Variant::ARRAY;
    if (!vector) {
        if (!numeric(v))
            return false;
        out.push_back(double(v));
        return true;
    }
    Array a = v;
    if (a.is_empty())
        return false;
    for (int64_t i = 0; i < a.size(); ++i) {
        if (!numeric(a[i]))
            return false;
        out.push_back(double(a[i]));
    }
    return true;
}
std::shared_ptr<bs::Curve> parse_curve(const Variant &value, int depth = 0) {
    if (value.get_type() != Variant::DICTIONARY || depth > 128)
        return {};
    Dictionary d = value;
    auto c = std::make_shared<bs::Curve>();
    c->values.clear();
    if (int(d.has("constant")) + int(d.has("keys")) + int(d.has("op")) != 1)
        return {};
    if (d.has("constant")) {
        if (!values(d["constant"], c->values, c->vector))
            return {};
        c->width = int(c->values.size());
        return c;
    }
    if (d.has("keys")) {
        c->kind = bs::Curve::KEYS;
        if (d.get("axis", String("temperature")).get_type() != Variant::STRING)
            return {};
        c->axis = text(String(d.get("axis", String("temperature"))));
        if (c->axis.empty())
            return {};
        c->strain_dependent = c->axis == "plastic_strain";
        if (d.get("interpolation", String("linear")).get_type() != Variant::STRING)
            return {};
        const String interpolation = d.get("interpolation", String("linear"));
        if (interpolation == "step")
            c->interpolation = bs::Curve::STEP;
        else if (interpolation == "cubic")
            c->interpolation = bs::Curve::CUBIC;
        else if (interpolation != "linear")
            return {};
        if (d["keys"].get_type() != Variant::ARRAY)
            return {};
        Array keys = d["keys"];
        if (keys.is_empty())
            return {};
        for (int64_t i = 0; i < keys.size(); ++i) {
            if (keys[i].get_type() != Variant::ARRAY)
                return {};
            Array key = keys[i];
            if (key.size() != 2 || !numeric(key[0]))
                return {};
            const double x = double(key[0]);
            if (i && x <= c->times.back())
                return {};
            std::vector<double> row;
            bool vector = false;
            if (!values(key[1], row, vector))
                return {};
            if (i == 0) {
                c->width = int(row.size());
                c->vector = vector;
            }
            if (int(row.size()) != c->width || vector != c->vector)
                return {};
            c->times.push_back(x);
            c->values.insert(c->values.end(), row.begin(), row.end());
        }
        return c;
    }
    if (d["op"].get_type() != Variant::STRING ||
        d.get("inputs", Variant()).get_type() != Variant::ARRAY)
        return {};
    const String op = d["op"];
    if (op == "add")
        c->kind = bs::Curve::ADD;
    else if (op == "multiply")
        c->kind = bs::Curve::MULTIPLY;
    else if (op == "min")
        c->kind = bs::Curve::MINIMUM;
    else if (op == "max")
        c->kind = bs::Curve::MAXIMUM;
    else
        return {};
    Array inputs = d["inputs"];
    if (inputs.size() < 2)
        return {};
    for (int64_t i = 0; i < inputs.size(); ++i) {
        auto child = parse_curve(inputs[i], depth + 1);
        if (!child)
            return {};
        c->width = std::max(c->width, child->width);
        c->vector = c->vector || child->vector;
        c->strain_dependent = c->strain_dependent || child->strain_dependent;
        c->inputs.push_back(child);
    }
    for (const auto &child : c->inputs)
        if (child->width != 1 && child->width != c->width)
            return {};
    return c;
}
bool parse_phase(const Variant &value, bs::Phase &phase) {
    if (value.get_type() != Variant::DICTIONARY)
        return false;
    Dictionary curves = value;
    Array keys = curves.keys();
    for (int64_t i = 0; i < keys.size(); ++i) {
        if (keys[i].get_type() != Variant::STRING)
            return false;
        auto curve = parse_curve(curves[keys[i]]);
        if (!curve)
            return false;
        phase.curves.emplace(text(String(keys[i])), std::move(curve));
    }
    phase.index();
    return true;
}
} // namespace
class BlacksmithNativeCore : public RefCounted {
    GDCLASS(BlacksmithNativeCore, RefCounted)
    bs::Solver solver;
    Array node_views, link_views, cell_views;
    std::vector<std::string> node_material_ids;
    std::map<std::string, int> material_indices;
    std::string diagnostic;
    double elapsed_us = 0;
    bool fail(const char *message) {
        diagnostic = message;
        return false;
    }

  protected:
    static void _bind_methods() {
        ClassDB::bind_method(D_METHOD("set_materials", "catalog"),
                             &BlacksmithNativeCore::set_materials);
        ClassDB::bind_method(D_METHOD("set_parameters", "tuning"),
                             &BlacksmithNativeCore::set_parameters);
        ClassDB::bind_method(D_METHOD("load_state", "nodes", "links", "cells", "discarded_mass"),
                             &BlacksmithNativeCore::load_state);
        ClassDB::bind_method(D_METHOD("download"), &BlacksmithNativeCore::download);
        ClassDB::bind_method(D_METHOD("step", "dt"), &BlacksmithNativeCore::step);
        ClassDB::bind_method(D_METHOD("hammer", "center", "normal", "radius", "mass", "velocity"),
                             &BlacksmithNativeCore::hammer);
        ClassDB::bind_method(D_METHOD("get_errors"), &BlacksmithNativeCore::get_errors);
        ClassDB::bind_method(D_METHOD("get_last_impulse"), &BlacksmithNativeCore::get_last_impulse);
        ClassDB::bind_method(D_METHOD("get_positions"), &BlacksmithNativeCore::get_positions);
        ClassDB::bind_method(D_METHOD("get_total_mass"), &BlacksmithNativeCore::get_total_mass);
        ClassDB::bind_method(D_METHOD("get_elapsed_usec"), &BlacksmithNativeCore::get_elapsed_usec);
        ClassDB::bind_method(D_METHOD("enable_profiling", "enabled"),
                             &BlacksmithNativeCore::enable_profiling);
        ClassDB::bind_method(D_METHOD("get_profile_usec"), &BlacksmithNativeCore::get_profile_usec);
        ClassDB::bind_method(D_METHOD("sample_material", "id", "property", "context"),
                             &BlacksmithNativeCore::sample_material);
    }

  public:
    bool set_materials(const Dictionary &catalog) {
        diagnostic.clear();
        Array ids = catalog.keys();
        std::vector<bs::Material> materials;
        std::map<std::string, int> indices;
        for (int64_t i = 0; i < ids.size(); ++i) {
            if (ids[i].get_type() != Variant::STRING ||
                catalog[ids[i]].get_type() != Variant::DICTIONARY)
                return fail("Invalid native material catalog.");
            Dictionary data = catalog[ids[i]];
            bs::Material material;
            bs::Phase base;
            if (!parse_phase(data.get("curves", Variant()), base))
                return fail("Invalid native base curves.");
            material.phases.push_back(std::move(base));
            Variant pv = data.get("phases", Array());
            if (pv.get_type() != Variant::ARRAY)
                return fail("Invalid native phase list.");
            Array phases = pv;
            for (int64_t j = 0; j < phases.size(); ++j) {
                if (phases[j].get_type() != Variant::DICTIONARY)
                    return fail("Invalid native phase.");
                Dictionary pd = phases[j];
                bs::Phase phase;
                if (!number(pd, "temperature", phase.temperature) ||
                    phase.temperature <= material.phases.back().temperature ||
                    !parse_phase(pd.get("curves", Variant()), phase))
                    return fail("Invalid native phase curves/threshold.");
                for (const auto &entry : phase.curves) {
                    auto original = material.phases.front().curves.find(entry.first);
                    if (original != material.phases.front().curves.end() &&
                        (original->second->width != entry.second->width ||
                         original->second->vector != entry.second->vector))
                        return fail("Native phase changed property shape.");
                }
                material.phases.push_back(std::move(phase));
            }
            indices.emplace(text(String(ids[i])), int(materials.size()));
            materials.push_back(std::move(material));
        }
        for (size_t i = 0; i < solver.state.nodes.size(); ++i) {
            auto found = indices.find(node_material_ids[i]);
            solver.state.nodes[i].material = found == indices.end() ? -1 : found->second;
        }
        solver.materials = std::move(materials);
        material_indices = std::move(indices);
        return true;
    }
    bool set_parameters(const Dictionary &d) {
        diagnostic.clear();
        bs::Parameters p;
        double substeps, iterations;
        if (!number(d, "minimum_step_s", p.minimum_step) ||
            !number(d, "maximum_step_s", p.maximum_step) ||
            !number(d, "minimum_length_m", p.minimum_length) ||
            !number(d, "anvil_height_m", p.anvil) ||
            (d.has("anvil_friction_coefficient") && !number(d, "anvil_friction_coefficient", p.anvil_friction)) ||
            !number(d, "hammer_impulse_transfer", p.transfer) ||
            !number(d, "hammer_contact_depth_m", p.depth) ||
            !number(d, "contact_tolerance_m", p.tolerance) || !number(d, "substeps", substeps) ||
            !number(d, "iterations", iterations) || substeps < 1 || iterations < 1 ||
            substeps != std::floor(substeps) || iterations != std::floor(iterations) ||
            substeps > std::numeric_limits<int>::max() ||
            iterations > std::numeric_limits<int>::max())
            return fail("Invalid native tuning.");
        Variant gv = d.get("gravity_m_s2", Variant());
        if (gv.get_type() != Variant::ARRAY)
            return fail("Invalid native gravity.");
        Array gravity = gv;
        if (gravity.size() != 3 || !numeric(gravity[0]) || !numeric(gravity[1]) ||
            !numeric(gravity[2]))
            return fail("Invalid native gravity.");
        p.gravity = {float(double(gravity[0])), float(double(gravity[1])),
                     float(double(gravity[2]))};
        p.substeps = int(substeps);
        p.iterations = int(iterations);
        if (!p.valid())
            return fail("Invalid native parameters.");
        solver.parameters = p;
        return true;
    }
    bool load_state(const Array &nodes, const Array &links, const Array &cells, double discarded) {
        diagnostic.clear();
        bs::State state;
        std::vector<std::string> names;
        if (!std::isfinite(discarded) || discarded < 0)
            return fail("Invalid discard ledger.");
        state.discarded_mass = discarded;
        state.nodes.reserve(nodes.size());
        state.links.reserve(links.size());
        state.cells.reserve(cells.size());
        for (int64_t i = 0; i < nodes.size(); ++i) {
            if (nodes[i].get_type() != Variant::DICTIONARY)
                return fail("Invalid native node object.");
            Dictionary d = nodes[i];
            bs::Node n;
            if (!vector_field(d, "position", n.position) ||
                !vector_field(d, "velocity", n.velocity) ||
                !basis_field(d, "orientation", n.orientation) ||
                !basis_field(d, "reference_orientation", n.reference_orientation) ||
                !number(d, "mass", n.mass) || n.mass <= 0 ||
                !number(d, "temperature", n.temperature) ||
                !number(d, "plastic_strain", n.strain) || n.strain < 0 ||
                d.get("material_id", Variant()).get_type() != Variant::STRING)
                return fail("Invalid native node state.");
            auto found = material_indices.find(text(String(d["material_id"])));
            if (found == material_indices.end())
                return fail("Unknown native node material.");
            n.material = found->second;
            names.push_back(text(String(d["material_id"])));
            Variant cv = d.get("composition", Variant()), iv = d.get("impurity_mass", Variant());
            if (cv.get_type() != Variant::DICTIONARY || iv.get_type() != Variant::DICTIONARY)
                return fail("Invalid composition/impurities.");
            Dictionary composition = cv, impurities = iv;
            Variant fraction = composition.get(d["material_id"], Variant());
            if (composition.size() != 1 || !numeric(fraction) || double(fraction) != 1)
                return fail("Native points require one constituent.");
            double impurity_sum = 0;
            Array amounts = impurities.values();
            for (int64_t j = 0; j < amounts.size(); ++j) {
                if (!numeric(amounts[j]) || double(amounts[j]) < 0)
                    return fail("Invalid impurity mass.");
                impurity_sum += double(amounts[j]);
            }
            if (impurity_sum > n.mass)
                return fail("Impurity mass exceeds node mass.");
            number(d, "plastic_strain_increment", n.increment);
            number(d, "plastic_spreading_increment", n.spreading);
            state.nodes.push_back(n);
        }
        for (int64_t i = 0; i < links.size(); ++i) {
            if (links[i].get_type() != Variant::DICTIONARY)
                return fail("Invalid native link object.");
            Dictionary d = links[i];
            bs::Link l;
            if (!index_field(d, "a", l.a) || !index_field(d, "b", l.b) || l.a == l.b ||
                size_t(l.a) >= state.nodes.size() || size_t(l.b) >= state.nodes.size() ||
                !number(d, "rest_length", l.rest) || l.rest <= 0 ||
                !number(d, "initial_length", l.initial) || l.initial <= 0 ||
                !number(d, "area", l.area) || l.area <= 0 || !number(d, "damping", l.damping) ||
                l.damping < 0 || !number(d, "fracture_damage", l.damage) || l.damage < 0 ||
                !vector_field(d, "reference_direction", l.direction) ||
                d.get("broken", Variant()).get_type() != Variant::BOOL)
                return fail("Invalid native link state.");
            l.broken = bool(d["broken"]);
            if (!l.broken && l.damage >= 1)
                return fail("Invalid unbroken damage.");
            number(d, "stiffness", l.stiffness);
            state.links.push_back(l);
        }
        for (int64_t i = 0; i < cells.size(); ++i) {
            if (cells[i].get_type() != Variant::DICTIONARY)
                return fail("Invalid native cell object.");
            Dictionary d = cells[i];
            bs::Cell c;
            if (!number(d, "rest_volume", c.rest) || c.rest <= 0 ||
                d.get("nodes", Variant()).get_type() != Variant::PACKED_INT32_ARRAY ||
                d.get("edges", Variant()).get_type() != Variant::PACKED_INT32_ARRAY)
                return fail("Invalid native cell.");
            PackedInt32Array ids = d["nodes"], edges = d["edges"];
            if (ids.size() != 8 || edges.size() != 12)
                return fail("Invalid native cell topology.");
            for (int j = 0; j < 8; ++j) {
                if (ids[j] < 0 || size_t(ids[j]) >= state.nodes.size())
                    return fail("Invalid cell node.");
                c.nodes[j] = ids[j];
            }
            for (int j = 0; j < 12; ++j) {
                if (edges[j] < 0 || size_t(edges[j]) >= state.links.size())
                    return fail("Invalid cell edge.");
                c.edges[j] = edges[j];
            }
            c.active = bool(d.get("active", true));
            state.cells.push_back(c);
        }
        solver.state = std::move(state);
        node_material_ids = std::move(names);
        node_views = nodes.duplicate(true);
        link_views = links.duplicate(true);
        cell_views = cells.duplicate(true);
        return true;
    }
    Dictionary download() {
        for (size_t i = 0; i < solver.state.nodes.size(); ++i) {
            Dictionary d = node_views[int64_t(i)];
            const auto &n = solver.state.nodes[i];
            d["position"] = pack(n.position);
            d["velocity"] = pack(n.velocity);
            d["orientation"] = pack(n.orientation);
            d["plastic_strain"] = n.strain;
            d["plastic_strain_increment"] = n.increment;
            d["plastic_spreading_increment"] = n.spreading;
        }
        for (size_t i = 0; i < solver.state.links.size(); ++i) {
            Dictionary d = link_views[int64_t(i)];
            const auto &l = solver.state.links[i];
            d["rest_length"] = l.rest;
            d["stiffness"] = l.stiffness;
            d["fracture_damage"] = l.damage;
            d["broken"] = l.broken;
        }
        for (size_t i = 0; i < solver.state.cells.size(); ++i) {
            Dictionary d = cell_views[int64_t(i)];
            d["active"] = solver.state.cells[i].active;
        }
        Dictionary result;
        result["nodes"] = node_views.duplicate(true);
        result["connections"] = link_views.duplicate(true);
        result["cells"] = cell_views.duplicate(true);
        return result;
    }
    bool step(double dt) {
        diagnostic.clear();
        auto start = std::chrono::steady_clock::now();
        bool ok = solver.step(dt);
        elapsed_us =
            std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - start)
                .count();
        return ok;
    }
    bool hammer(Vector3 center, Vector3 normal, double radius, double mass, Vector3 velocity) {
        diagnostic.clear();
        return solver.hammer(unpack(center), unpack(normal), radius, mass, unpack(velocity));
    }
    PackedStringArray get_errors() const {
        PackedStringArray errors;
        if (!diagnostic.empty())
            errors.push_back(String(diagnostic.c_str()));
        else if (!solver.error.empty())
            errors.push_back(String(solver.error.c_str()));
        return errors;
    }
    Vector3 get_last_impulse() const { return pack(solver.last_impulse); }
    double get_total_mass() const { return solver.total_mass(); }
    double get_elapsed_usec() const { return elapsed_us; }
    void enable_profiling(bool enabled) { solver.profiling = enabled; }
    Dictionary get_profile_usec() const {
        Dictionary result;
        const char *names[] = {"validation_and_snapshot",
                               "material_and_prediction",
                               "plasticity_and_setup",
                               "spring_constraints",
                               "volume_constraints",
                               "anvil_and_damping",
                               "orientation"};
        for (int i = 0; i < 7; ++i)
            result[names[i]] = solver.profile_usec[i];
        return result;
    }
    PackedVector3Array get_positions() const {
        PackedVector3Array result;
        result.resize(solver.state.nodes.size());
        for (size_t i = 0; i < solver.state.nodes.size(); ++i)
            result.ptrw()[i] = pack(solver.state.nodes[i].position);
        return result;
    }
    Variant sample_material(const String &id, const String &property,
                            const Dictionary &context) const {
        auto found = material_indices.find(text(id));
        double temperature;
        if (found == material_indices.end() || !number(context, "temperature", temperature))
            return Variant();
        const auto *phase = solver.materials[found->second].phase(temperature);
        if (!phase)
            return Variant();
        auto curve = phase->curves.find(text(property));
        if (curve == phase->curves.end())
            return Variant();
        bs::Context ctx{temperature, std::numeric_limits<double>::quiet_NaN(), nullptr};
        number(context, "plastic_strain", ctx.strain);
        std::map<std::string, double> extras;
        Array keys = context.keys();
        for (int64_t i = 0; i < keys.size(); ++i)
            if (keys[i].get_type() == Variant::STRING && numeric(context[keys[i]]))
                extras.emplace(text(String(keys[i])), double(context[keys[i]]));
        ctx.extra = &extras;
        const auto &c = *curve->second;
        if (!c.vector) {
            double value = c.eval(ctx);
            return std::isfinite(value) ? Variant(value) : Variant();
        }
        PackedFloat64Array result;
        for (int lane = 0; lane < c.width; ++lane) {
            double value = c.eval(ctx, lane);
            if (!std::isfinite(value))
                return Variant();
            result.push_back(value);
        }
        return result;
    }
};
extern "C" GDExtensionBool GDE_EXPORT blacksmith_library_init(
    GDExtensionInterfaceGetProcAddress get_proc_address, GDExtensionClassLibraryPtr library,
    GDExtensionInitialization *initialization) {
    GDExtensionBinding::InitObject init(get_proc_address, library, initialization);
    init.register_initializer([](ModuleInitializationLevel level) {
        if (level == MODULE_INITIALIZATION_LEVEL_SCENE)
            ClassDB::register_class<BlacksmithNativeCore>();
    });
    init.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);
    return init.init();
}
