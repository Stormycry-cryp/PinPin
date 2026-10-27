using PinPin.Core;

namespace PinPin.Presentation.Models;

internal enum CardMode { Hidden, Short, Dialog }

/// One persistent model per result. Hiding a view never deletes its answer, task or draft.
internal sealed class ResultModel
{
    public ResultState State { get; private set; }
    public Guid Id => State.Id;
    public CardMode Mode { get; set; }
    public bool Peek { get; set; }
    public bool SourceVisible { get; set; } = true;
    public string Draft { get; set; } = "";
    public string DisplayText { get; private set; } = "";
    public string? ErrorNotice { get; private set; }
    public string? SubmittedQuestion { get; private set; }
    public string LastCompleteAnswer { get; private set; } = "";
    public bool RequestPending { get; private set; }
    public bool Busy => RequestPending || State.IsLoading || State.IsAnswering;
    public bool IsFailure => !string.IsNullOrEmpty(State.Error) && string.IsNullOrEmpty(DisplayText) && State.Saved is null && State.Color is null;
    public bool CanFollowup => State.Action is not (ActionKind.Save or ActionKind.PickColor) && !IsFailure && !Busy
        && (State.IsComplete || (State.Error is not null && LastCompleteAnswer.Length > 0));
    public event Action? Changed;

    public ResultModel(ResultState state) { State = state; Apply(state); }
    public void Apply(ResultState state)
    {
        State = state;
        RequestPending = false;
        if (!string.IsNullOrEmpty(state.Error) && SubmittedQuestion is not null)
        {
            DisplayText = string.IsNullOrEmpty(state.Text) ? LastCompleteAnswer : state.Text;
            if (string.IsNullOrWhiteSpace(Draft)) Draft = SubmittedQuestion;
            ErrorNotice = state.Error;
            SubmittedQuestion = null;
        }
        else
        {
            DisplayText = state.Text;
            if (state.IsComplete && !state.IsAnswering && state.Error is null)
            { LastCompleteAnswer = state.Text; SubmittedQuestion = null; ErrorNotice = null; }
            else if (state.Error is not null) ErrorNotice = state.Error;
        }
        Changed?.Invoke();
    }

    public bool Submit(Action<Guid, string>? send)
    {
        string question = Draft.Trim();
        if (question.Length == 0 || !CanFollowup || send is null) return false;
        LastCompleteAnswer = DisplayText;
        SubmittedQuestion = question;
        Draft = ""; ErrorNotice = null; RequestPending = true;
        Changed?.Invoke();
        send(Id, question);
        return true;
    }
}
