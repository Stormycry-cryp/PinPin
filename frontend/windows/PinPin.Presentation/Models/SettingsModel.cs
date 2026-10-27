using PinPin.Core;

namespace PinPin.Presentation.Models;

internal sealed class SettingsModel
{
    public WheelSettings Value { get; private set; } = WheelSettings.Default;
    public bool SaveFailed { get; private set; }
    public bool Saving { get; private set; }
    public int Revision { get; private set; }
    public Func<WheelSettings, Task<bool>>? Save { get; set; }
    public event Action? Changed;
    public event Action<WheelSettings>? Previewed;

    public static bool Equal(WheelSettings a, WheelSettings b) => a.TriggerEnabled == b.TriggerEnabled && a.Slots.SequenceEqual(b.Slots)
        && a.Colors.Count == b.Colors.Count && a.Colors.All(x => b.Colors.TryGetValue(x.Key, out var c) && c == x.Value);
    public void Receive(WheelSettings settings)
    {
        if (!settings.IsValid || Equal(Value, settings)) return;
        // Host snapshots have no edit revision; a late startup/read snapshot cannot replace a pending local edit.
        if (Saving || SaveFailed) return;
        Value = settings.Copy(); Changed?.Invoke();
    }
    public void Apply(WheelSettings settings)
    {
        if (!settings.IsValid || Equal(Value, settings)) return;
        Value = settings.Copy(); Revision++; SaveFailed = false; Saving = true;
        Previewed?.Invoke(Value.Copy()); Changed?.Invoke(); Persist(Revision);
    }
    public void Retry() { if (!SaveFailed) return; Revision++; SaveFailed = false; Saving = true; Changed?.Invoke(); Persist(Revision); }
    private async void Persist(int revision)
    {
        if (revision != Revision) return;
        var snapshot = Value.Copy(); bool success = false;
        try { if (Save is { } save) success = await save(snapshot); }
        catch (Exception) { success = false; }
        if (revision != Revision) return;
        Saving = false; SaveFailed = !success; Changed?.Invoke();
    }
    public void Count(int count)
    {
        count = Math.Clamp(count, 1, 8); if (count == Value.Slots.Length) return;
        var slots = new ActionKind?[count]; Array.Copy(Value.Slots, slots, Math.Min(count, Value.Slots.Length));
        Apply(Value with { Slots = slots });
    }
    public void Trigger(bool enabled) => Apply(Value with { TriggerEnabled = enabled });
    public void Color(ActionKind action, FeatureColor color)
    {
        var settings = Value.Copy();
        if (color == Palette.Default(action)) settings.Colors.Remove(action); else settings.Colors[action] = color;
        Apply(settings);
    }
    public void Assign(int slot, ActionKind? action)
    { if (slot < 0 || slot >= Value.Slots.Length) return; var next = Value.Copy(); next.Slots[slot] = action; Apply(next); }
    public static WheelSettings Drop(WheelSettings value, ActionKind action, int? sourceSlot, int? targetSlot, bool outsideTray)
    {
        var next = value.Copy();
        if (targetSlot is { } target)
        {
            if (target < 0 || target >= next.Slots.Length) return next;
            if (sourceSlot is { } from && from >= 0 && from < next.Slots.Length)
                (next.Slots[from], next.Slots[target]) = (next.Slots[target], next.Slots[from]);
            else next.Slots[target] = action;
        }
        else if (outsideTray && sourceSlot is { } from && from >= 0 && from < next.Slots.Length) next.Slots[from] = null;
        return next;
    }
}
